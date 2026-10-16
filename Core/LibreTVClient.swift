import Foundation

final class APIRequestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The API uses fixed routes; no redirect needs to carry a password or session.
        completionHandler(nil)
    }
}

@MainActor final class LibreTVClient {
    let server: ServerAddress
    private(set) var sources: [SourceConfig] = []
    private let session: URLSession
    private let coverCache = NSCache<NSString, NSData>()
    private var isDisconnected = false
    private var sessionGeneration = 0

    init(server: ServerAddress, protocolClasses: [AnyClass]? = nil) {
        self.server = server
        coverCache.totalCostLimit = 32 * 1024 * 1024
        coverCache.countLimit = 60
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 75
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: APIRequestDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func status() async throws -> ServerStatus {
        let result: ServerStatus = try await send(request(path: "/api/status", timeout: 15))
        var seen = Set<String>()
        sources = result.defaultSources.filter {
            $0.isAdult != true && !$0.key.isEmpty && seen.insert($0.key).inserted
        }
        return result
    }

    func login(password: String) async throws {
        guard !password.isEmpty else { throw LibreTVError.wrongPassword }
        let body = try JSONEncoder().encode(LoginBody(password: password))
        let response: LoginResponse = try await send(request(path: "/api/auth", body: body, timeout: 15))
        guard response.success else { throw LibreTVError.wrongPassword }
    }

    func search(query: String) async throws -> SearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw LibreTVError.emptyQuery }
        guard !sources.isEmpty else { throw LibreTVError.noSources }
        let body = try JSONEncoder().encode(SearchBody(wd: query, sources: sources, filterAdult: true))
        let response: SearchResponse = try await send(request(path: "/api/search", body: body, timeout: 60))
        let allowedKeys = Set(sources.map(\.key))
        var seen = Set<String>()
        return SearchResponse(list: response.list.filter {
            $0.isAdult != true && allowedKeys.contains($0.sourceKey) && seen.insert($0.id).inserted
        }, failures: response.failures)
    }

    func detail(for item: SearchItem) async throws -> VideoDetail {
        guard let source = sources.first(where: { $0.key == item.sourceKey }) else {
            throw LibreTVError.unknownSource
        }
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        return try await send(request(path: "/api/detail", query: [
            URLQueryItem(name: "id", value: item.vodId),
            URLQueryItem(name: "source", value: encoded)
        ], timeout: 40))
    }

    func recommendations(for category: RecommendationCategory) async throws -> [RecommendationItem] {
        let items: [RecommendationItem]
        if let id = category.hotListID {
            let response: RecommendationResponse = try await send(request(path: "/api/hot-list", query: [
                URLQueryItem(name: "id", value: id)
            ]))
            items = response.items
        } else if category == .anime {
            let response: AnimeCalendar = try await send(request(path: "/api/bangumi/calendar"))
            items = response.days.sorted { $0.weekday < $1.weekday }.flatMap(\.items)
        } else {
            let response: RecommendationResponse = try await send(request(path: "/api/douban", query: [
                URLQueryItem(name: "type", value: category == .popularTV ? "tv" : "movie"),
                URLQueryItem(name: "tag", value: category == .highRatedMovies ? "豆瓣高分" : "热门"),
                URLQueryItem(name: "pageStart", value: "0"),
                URLQueryItem(name: "pageSize", value: "50")
            ]))
            items = response.items
        }
        var seen = Set<String>()
        return items.filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }
    }

    func playbackRequest(for episode: String) throws -> PlaybackRequest {
        let proxy = try proxyRequest(for: episode).url!
        return PlaybackRequest(url: proxy, cookies: cookies(for: proxy))
    }

    func coverData(for address: String) async throws -> Data {
        try Task.checkCancellation()
        guard !isDisconnected else { throw CancellationError() }
        let generation = sessionGeneration
        var request = try proxyRequest(for: address)
        if let cached = coverCache.object(forKey: address as NSString) { return cached as Data }
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let limit = 5 * 1024 * 1024
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            let http = try validateResponse(response, for: request, generation: generation)
            guard http.mimeType?.lowercased().hasPrefix("image/") == true,
                  http.expectedContentLength <= Int64(limit) else { throw LibreTVError.invalidResponse }
            let data = try await Self.readCover(bytes, limit: limit)
            try Task.checkCancellation()
            guard !isDisconnected, generation == sessionGeneration else { throw CancellationError() }
            coverCache.setObject(data as NSData, forKey: address as NSString, cost: data.count)
            return data
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? LibreTVError.timedOut : LibreTVError.networkUnavailable
        }
    }

    nonisolated private static func readCover(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        // Keep per-byte iteration off the main actor so poster loading does not delay the remote.
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw LibreTVError.invalidResponse }
            data.append(byte)
        }
        return data
    }

    private func proxyRequest(for address: String) throws -> URLRequest {
        guard let media = URLComponents(string: address),
              let scheme = media.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = media.host, !host.isEmpty,
              media.user == nil, media.password == nil, media.url != nil else {
            throw LibreTVError.invalidMediaURL
        }
        return try request(path: "/api/proxy", query: [URLQueryItem(name: "url", value: address)])
    }

    func disconnect() {
        isDisconnected = true
        clearCookies()
        sources = []
        session.invalidateAndCancel()
    }

    private func clearCookies() {
        sessionGeneration += 1
        coverCache.removeAllObjects()
        guard let storage = session.configuration.httpCookieStorage else { return }
        for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
    }

    private func cookies(for url: URL) -> [HTTPCookie] {
        (session.configuration.httpCookieStorage?.cookies(for: url) ?? []).filter {
            $0.name == "ltv_session" && $0.domain == server.url.host
        }
    }

    private func request(path: String, query: [URLQueryItem] = [], body: Data? = nil,
                         timeout: TimeInterval = 30) throws -> URLRequest {
        var parts = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        // Next.js parses query strings as form data, where an unescaped plus means a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw LibreTVError.invalidServerAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies(for: url)) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        guard !isDisconnected else { throw CancellationError() }
        let generation = sessionGeneration
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? LibreTVError.timedOut : LibreTVError.networkUnavailable
        }
        _ = try validateResponse(response, for: request, generation: generation)
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw LibreTVError.invalidResponse }
    }

    private func validateResponse(_ response: URLResponse, for request: URLRequest, generation: Int) throws -> HTTPURLResponse {
        try Task.checkCancellation()
        guard !isDisconnected, generation == sessionGeneration else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw LibreTVError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw LibreTVError.redirectBlocked
        case 401:
            clearCookies()
            throw request.url?.path == "/api/auth" ? LibreTVError.wrongPassword : LibreTVError.unauthorized
        case 429: throw LibreTVError.rateLimited
        case 503 where request.url?.path == "/api/auth": throw LibreTVError.passwordNotConfigured
        default: throw LibreTVError.requestFailed(http.statusCode)
        }
        if request.url?.path == "/api/auth", let header = http.value(forHTTPHeaderField: "Set-Cookie") {
            // Keep API login and AVPlayer on the same private in-memory cookie store.
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: server.url)
                .filter { $0.name == "ltv_session" && $0.domain == server.url.host }
            if !cookies.isEmpty { clearCookies() }
            session.configuration.httpCookieStorage?.setCookies(cookies, for: server.url, mainDocumentURL: server.url)
        }
        return http
    }
}

private struct LoginBody: Encodable { let password: String }
private struct LoginResponse: Decodable { let success: Bool }
private struct SearchBody: Encodable {
    let wd: String
    let sources: [SourceConfig]
    let filterAdult: Bool
}
