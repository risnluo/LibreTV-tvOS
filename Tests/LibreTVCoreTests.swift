import Foundation
#if !LIBRETV_SELF_CHECK
import XCTest
@testable import LibreTVCore
#endif

enum ContractChecks {
    static let sourceJSON = #"{"key":"env_0","name":"家庭片源","url":"https://source.example.test/api.php?token=a&b=c","detail":"https://source.example.test"}"#
    static let statusJSON = #"{"passwordRequired":true,"verified":true,"version":"2.16.12","defaultSources":["# + sourceJSON + "]}"
    static let detailJSON = #"{"episodes":["https://media.example.test/watch.m3u8?key=a&token=b%2Bc"],"videoInfo":{"title":"测试影片","sourceKey":"env_0","sourceName":"家庭片源"}}"#

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw CheckFailure(message: message) }
    }

    static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw CheckFailure(message: "Invalid input was accepted")
    }

    static func serverAddress() throws {
        try expect(try ServerAddress("  http://192.0.2.10:8899/  ").url.absoluteString ==
                   "http://192.0.2.10:8899", "Root address should normalize")
        try expect(try ServerAddress("https://nas.example.test").url.host == "nas.example.test",
                   "HTTPS address should be accepted")
        for input in ["", "192.0.2.10:8899", "file:///tmp/video", "ftp://nas.test",
                      "http://user:secret@nas.test", "http://nas.test/?password=x",
                      "http://nas.test/#x", "http://nas.test/libretv", "http://nas.test:99999"] {
            try rejects { _ = try ServerAddress(input) }
        }
    }

    @MainActor static func requestContract() async throws {
        var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            switch request.url!.path {
            case "/api/status": return (200, statusJSON, [:])
            case "/api/auth": return (200, #"{"success":true}"#, [:])
            case "/api/search":
                return (200, #"{"list":[{"sourceKey":"env_0","sourceName":"家庭片源","vodId":"film-1","name":"测试影片","sourceUrl":"https://untrusted.example.test"}],"failures":[{"sourceKey":"env_1","error":"https://private.test/?secret=x","timedOut":true}]}"#, [:])
            case "/api/detail": return (200, detailJSON, [:])
            default: throw CheckFailure(message: "Unexpected API path")
            }
        }
        let client = try makeClient()
        defer { client.disconnect() }
        let status = try await client.status()
        try expect(status.defaultSources.count == 1, "Server sources must decode")
        try await client.login(password: "test-only-password")
        let response = try await client.search(query: " 西游记 ")
        try expect(response.list.count == 1 && response.failures.count == 1,
                   "A failing source must not discard successful results")
        let detail = try await client.detail(for: response.list[0])
        try expect(detail.episodes.count == 1, "Detail should decode plain URL episodes")
        let auth = try body(requests[1])
        try expect(auth["password"] as? String == "test-only-password", "Auth JSON field must be password")
        try expect(requests[1].httpMethod == "POST", "Login must POST")
        let search = try body(requests[2])
        try expect(search["wd"] as? String == "西游记", "Search must trim and use wd")
        try expect(search["filterAdult"] as? Bool == true, "Adult filter must stay on")
        try expect((search["sources"] as? [[String: Any]])?.first?["key"] as? String == "env_0",
                   "Search must use server sources")
        let query = URLComponents(url: requests[3].url!, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(query.first { $0.name == "id" }?.value == "film-1", "Detail ID must round trip")
        let sourceData = Data(query.first { $0.name == "source" }!.value!.utf8)
        let source = try JSONDecoder().decode(SourceConfig.self, from: sourceData)
        try expect(source.url == "https://source.example.test/api.php?token=a&b=c",
                   "Detail must use matching configured source, never result sourceUrl")
        try expect(requests.allSatisfy { $0.timeoutInterval > 0 && $0.timeoutInterval <= 75 },
                   "Every request needs a bounded timeout")
    }

    @MainActor static func sourceBoundaries() async throws {
        StubProtocol.handler = { _ in (200, #"{"passwordRequired":true,"verified":true,"version":"2.16.12","defaultSources":[]}"#, [:]) }
        let client = try makeClient()
        defer { client.disconnect() }
        _ = try await client.status()
        do { _ = try await client.search(query: "电影"); throw CheckFailure(message: "Empty sources allowed") }
        catch LibreTVError.noSources {}
        let item = try JSONDecoder().decode(SearchItem.self, from: Data(#"{"sourceKey":"unknown","sourceName":"未知","vodId":"1","name":"测试"}"#.utf8))
        do { _ = try await client.detail(for: item); throw CheckFailure(message: "Unconfigured source allowed") }
        catch LibreTVError.unknownSource {}
        do { _ = try await client.search(query: " \n "); throw CheckFailure(message: "Empty query allowed") }
        catch LibreTVError.emptyQuery {}
    }

    @MainActor static func errorsAreSanitized() async throws {
        let client = try makeClient()
        defer { client.disconnect() }
        StubProtocol.handler = { _ in (401, #"{"error":"password=do-not-display https://secret.test"}"#, [:]) }
        do { _ = try await client.status(); throw CheckFailure(message: "401 accepted") }
        catch LibreTVError.unauthorized {}
        do { try await client.login(password: "fake"); throw CheckFailure(message: "Wrong password accepted") }
        catch LibreTVError.wrongPassword {}
        StubProtocol.handler = { _ in (503, "secret upstream body", [:]) }
        do { try await client.login(password: "fake"); throw CheckFailure(message: "Unconfigured server accepted") }
        catch LibreTVError.passwordNotConfigured {}
        StubProtocol.handler = { _ in (200, "invalid JSON containing a secret", [:]) }
        do { _ = try await client.status(); throw CheckFailure(message: "Invalid JSON accepted") }
        catch LibreTVError.invalidResponse {}
        try expect(!LibreTVError.invalidResponse.localizedDescription.contains("secret"), "Errors should be generic")
        StubProtocol.handler = { _ in (200, #"{"success":false}"#, [:]) }
        do { try await client.login(password: "fake"); throw CheckFailure(message: "False success accepted") }
        catch LibreTVError.wrongPassword {}
    }

    @MainActor static func proxyAndCookies() async throws {
        StubProtocol.handler = { request in
            if request.url?.path == "/api/status" {
                try expect(request.value(forHTTPHeaderField: "Cookie")?.contains("ltv_session=fake-test-session") == true,
                           "Authenticated API calls must use the private session cookie")
                return (200, statusJSON, [:])
            }
            return (200, #"{"success":true}"#, ["Set-Cookie": "ltv_session=fake-test-session; HttpOnly; Path=/"])
        }
        let client = try makeClient()
        let otherClient = try makeClient()
        defer { client.disconnect(); otherClient.disconnect() }
        try await client.login(password: "fake")
        _ = try await client.status()
        let upstream = "https://media.example.test/movie.m3u8?token=a+b&nested=x%26y"
        let playback = try client.playbackRequest(for: upstream)
        let parts = URLComponents(url: playback.url, resolvingAgainstBaseURL: false)!
        try expect(parts.host == "nas.example.test" && parts.port == 8899 && parts.path == "/api/proxy",
                   "Playback must target the configured NAS proxy")
        try expect(parts.queryItems?.first?.value == upstream, "Signed upstream URL must round trip unchanged")
        try expect(playback.cookies.count == 1 && playback.cookies[0].domain == "nas.example.test",
                   "Only applicable NAS session cookies should accompany playback (count: \(playback.cookies.count))")
        try expect(try otherClient.playbackRequest(for: upstream).cookies.isEmpty, "Clients must not share cookies")
        for invalid in ["file:///tmp/movie", "javascript:alert(1)", "/relative.m3u8", "http://user:pass@media.test/x"] {
            try rejects { _ = try client.playbackRequest(for: invalid) }
        }
        StubProtocol.handler = { _ in (401, "", [:]) }
        do { _ = try await client.status(); throw CheckFailure(message: "Expired session accepted") }
        catch LibreTVError.unauthorized {}
        try expect(try client.playbackRequest(for: upstream).cookies.isEmpty, "Unauthorized response must erase stale cookies")
        StubProtocol.handler = { _ in (200, #"{"success":true}"#, ["Set-Cookie": "ltv_session=fake-test-session; HttpOnly; Path=/"]) }
        try await client.login(password: "fake")
        client.disconnect()
        try expect(try client.playbackRequest(for: upstream).cookies.isEmpty, "Disconnect must erase cookies")
    }

    @MainActor static func sourceFiltering() async throws {
        let adultSource = sourceJSON.replacingOccurrences(of: #""key":"env_0""#, with: #""key":"adult","isAdult":true"#)
        let configured = #"{"passwordRequired":true,"verified":true,"version":"2.16.12","defaultSources":["# +
            [sourceJSON, sourceJSON, adultSource].joined(separator: ",") + "]}"
        let valid = #"{"sourceKey":"env_0","sourceName":"家庭片源","vodId":"1","name":"测试"}"#
        let adultResult = valid.replacingOccurrences(of: #""vodId":"1""#, with: #""vodId":"2","isAdult":true"#)
        let unknownResult = valid.replacingOccurrences(of: "env_0", with: "unknown")
        StubProtocol.handler = { request in
            if request.url?.path == "/api/status" { return (200, configured, [:]) }
            return (200, #"{"list":["# + [valid, valid, adultResult, unknownResult].joined(separator: ",") + #"],"failures":[]}"#, [:])
        }
        let client = try makeClient()
        defer { client.disconnect() }
        _ = try await client.status()
        try expect(client.sources.map(\.key) == ["env_0"], "Adult and duplicate sources must be excluded")
        let result = try await client.search(query: "电影")
        try expect(result.list.count == 1 && result.list[0].vodId == "1",
                   "Only unique non-adult results from configured sources may appear")
    }

    @MainActor static func queryPlusEncoding() async throws {
        let sourceWithPlus = statusJSON.replacingOccurrences(of: "token=a&b=c", with: "token=a+b&b=c")
        StubProtocol.handler = { request in
            if request.url?.path == "/api/status" { return (200, sourceWithPlus, [:]) }
            let query = formQuery(request.url!)
            let source = try JSONDecoder().decode(SourceConfig.self, from: Data(query["source"]!.utf8))
            try expect(source.url.contains("token=a+b"), "NAS must receive literal plus in source JSON")
            return (200, detailJSON, [:])
        }
        let client = try makeClient()
        defer { client.disconnect() }
        let upstream = "https://media.example.test/movie.m3u8?token=a+b&nested=x%26y"
        let playback = try client.playbackRequest(for: upstream)
        try expect(formQuery(playback.url)["url"] == upstream,
                   "NAS form-query decoding must preserve signed URL plus characters")
        _ = try await client.status()
        let item = try JSONDecoder().decode(SearchItem.self, from: Data(#"{"sourceKey":"env_0","sourceName":"家庭片源","vodId":"film-1","name":"测试"}"#.utf8))
        _ = try await client.detail(for: item)
    }

    static func formQuery(_ url: URL) -> [String: String] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQuery ?? ""
        return Dictionary(uniqueKeysWithValues: query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode: (Substring) -> String = {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!
            }
            return (decode(parts[0]), decode(parts[1]))
        })
    }

    @MainActor static func redirectsAreBlocked() async throws {
        let policy = APIRequestDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://nas.example.test:8899/api/auth")!)
        for target in ["https://untrusted.example.test", "http://nas.example.test:8899/other"] {
            let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 307,
                                           httpVersion: nil, headerFields: ["Location": target])!
            var rejected = false
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: URL(string: target)!)) { request in
                rejected = request == nil
            }
            try expect(rejected, "API redirect must not resend login credentials")
        }
        let client = try makeClient()
        defer { client.disconnect() }
        StubProtocol.handler = { _ in (302, "", ["Location": "https://untrusted.example.test"]) }
        do { _ = try await client.status(); throw CheckFailure(message: "Redirect response accepted") }
        catch LibreTVError.redirectBlocked {}
    }

    @MainActor static func cancellation() async throws {
        StubProtocol.handler = { _ in nil }
        let client = try makeClient()
        defer { client.disconnect() }
        let task = Task { try await client.status() }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; throw CheckFailure(message: "Cancellation ignored") }
        catch is CancellationError {}
    }

    @MainActor static func recommendationEndpoints() async throws {
        let expected: [(RecommendationCategory, String, [String: String])] = [
            (.movieWeekly, "/api/hot-list", ["id": "douban_movie_weekly"]),
            (.chineseTV, "/api/hot-list", ["id": "douban_tv_chinese"]),
            (.globalTV, "/api/hot-list", ["id": "douban_tv_global"]),
            (.chineseVariety, "/api/hot-list", ["id": "douban_show_chinese"]),
            (.globalVariety, "/api/hot-list", ["id": "douban_show_global"]),
            (.baiduTV, "/api/hot-list", ["id": "baidu_teleplay"]),
            (.popularMovies, "/api/douban", ["type": "movie", "tag": "热门", "pageStart": "0", "pageSize": "50"]),
            (.popularTV, "/api/douban", ["type": "tv", "tag": "热门", "pageStart": "0", "pageSize": "50"]),
            (.highRatedMovies, "/api/douban", ["type": "movie", "tag": "豆瓣高分", "pageStart": "0", "pageSize": "50"]),
            (.anime, "/api/bangumi/calendar", [:])
        ]
        try expect(Set(expected.map { $0.0 }) == Set(RecommendationCategory.allCases), "Every category needs a verified route")
        let client = try makeClient()
        defer { client.disconnect() }
        for (category, path, query) in expected {
            var requestCount = 0
            StubProtocol.handler = { request in
                requestCount += 1
                try expect(request.url?.host == "nas.example.test" && request.url?.port == 8899,
                           "Recommendation requests must remain on the configured NAS")
                try expect(request.url?.path == path && formQuery(request.url!) == query,
                           "Wrong recommendation route or query for \(category)")
                try expect(request.httpMethod == "GET", "Recommendation requests must GET")
                let item = #"{"id":"1","title":"测试影片","cover":"https://poster.example.test/a.jpg","rating":"8.6","isTv":true}"#
                let json = category == .anime ? #"{"days":[{"weekday":1,"items":["# + item + "]}]}" : #"{"items":["# + item + "]}"
                return (200, json, [:])
            }
            let items = try await client.recommendations(for: category)
            try expect(requestCount == 1 && items.count == 1, "Each category must load its items")
            try expect(items[0].title == "测试影片" && items[0].rating == "8.6" && items[0].isTv == true,
                       "Recommendation fields must decode")
            try expect(category.id == category.rawValue && !category.title.isEmpty, "Categories need stable identity and display title")
        }
    }

    @MainActor static func recommendationFiltering() async throws {
        let entries = #"[{"id":"1","title":"无封面影片"},{"id":"1","title":"重复"},{"id":"","title":"空编号"},{"id":" \n ","title":"空白编号"},{"id":"2","title":""},{"id":"3","title":" \n "},{"id":"4","title":"另一影片","cover":null,"rating":null}]"#
        StubProtocol.handler = { request in
            let json = request.url?.path == "/api/bangumi/calendar" ? #"{"days":[{"weekday":1,"items":"# + entries + "}]}" : #"{"items":"# + entries + "}"
            return (200, json, [:])
        }
        let client = try makeClient()
        defer { client.disconnect() }
        for category in RecommendationCategory.allCases {
            let items = try await client.recommendations(for: category)
            try expect(items.map(\.id) == ["1", "4"], "Empty IDs/titles and duplicate IDs must be removed for every category")
            try expect(items.allSatisfy { $0.cover == nil && $0.rating == nil && $0.isTv == nil },
                       "Missing optional poster metadata must retain the title for a placeholder")
        }
    }

    @MainActor static func animeOrdering() async throws {
        StubProtocol.handler = { _ in
            (200, #"{"days":[{"weekday":7,"items":[{"id":"last","title":"周日"},{"id":"shared","title":"重复"}]},{"weekday":1,"items":[{"id":"first","title":"周一"},{"id":"shared","title":"首次出现"}]},{"weekday":3,"items":[{"id":"middle","title":"周三"}]}]}"#, [:])
        }
        let client = try makeClient()
        defer { client.disconnect() }
        let items = try await client.recommendations(for: .anime)
        try expect(items.map(\.id) == ["first", "shared", "middle", "last"], "Anime must sort days before flattening and deduplicating")
        try expect(items[1].title == "首次出现", "Deduplication must keep the first item in weekday order")
    }

    @MainActor static func coverProxyAndCache() async throws {
        let upstream = "https://poster.example.test/海报.jpg?token=a+b&nested=x%26y"
        let fixture = "\u{0}image-fixture"
        var imageRequests = 0
        StubProtocol.handler = { request in
            if request.url?.path == "/api/auth" {
                return (200, #"{"success":true}"#, ["Set-Cookie": "ltv_session=fake-test-session; HttpOnly; Path=/"])
            }
            imageRequests += 1
            try expect(request.url?.host == "nas.example.test" && request.url?.port == 8899 && request.url?.path == "/api/proxy",
                       "Covers must load through NAS, never directly from the upstream")
            try expect(formQuery(request.url!)["url"] == upstream, "Nested cover URL must preserve literal plus, percent escapes and Unicode")
            try expect(request.value(forHTTPHeaderField: "Cookie") == "ltv_session=fake-test-session",
                       "Cover proxy must use the private NAS cookie")
            try expect(request.value(forHTTPHeaderField: "Accept") == "image/*", "Cover proxy should request image content")
            return (200, fixture, ["Content-Type": "image/jpeg"])
        }
        let client = try makeClient()
        defer { client.disconnect() }
        try await client.login(password: "fake")
        let first = try await client.coverData(for: upstream)
        let cached = try await client.coverData(for: upstream)
        try expect(first == Data(fixture.utf8) && cached == first && imageRequests == 1,
                   "Cover cache must reuse the received bytes within this client")
        let other = try makeClient()
        defer { other.disconnect() }
        try await other.login(password: "fake")
        _ = try await other.coverData(for: upstream)
        try expect(imageRequests == 2, "Clients must have separate image caches")
        client.disconnect()
        do { _ = try await client.coverData(for: upstream); throw CheckFailure(message: "Disconnected client returned cached image") }
        catch is LibreTVError {}
        catch is CancellationError {}
    }

    @MainActor static func coverValidation() async throws {
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            return (200, "fixture", ["Content-Type": "image/png"])
        }
        let client = try makeClient()
        defer { client.disconnect() }
        for invalid in ["", "file:///tmp/poster.jpg", "javascript:alert(1)", "/poster.jpg", "https:///", "http://user:pass@poster.test/x", "http://user@poster.test/x"] {
            do { _ = try await client.coverData(for: invalid); throw CheckFailure(message: "Invalid cover URL accepted") }
            catch LibreTVError.invalidMediaURL {}
        }
        try expect(requests == 0, "Invalid cover URLs must be rejected before any request")
        for headers in [["Content-Type": "text/html"], ["Content-Type": "application/json"], [:]] {
            StubProtocol.handler = { _ in (200, "private upstream response", headers) }
            do { _ = try await client.coverData(for: "https://poster.test/a"); throw CheckFailure(message: "Non-image content accepted") }
            catch LibreTVError.invalidResponse {}
        }
    }

    @MainActor static func coverSizeLimit() async throws {
        let limit = 5 * 1024 * 1024
        let client = try makeClient()
        defer { client.disconnect() }
        StubProtocol.handler = { _ in (200, "x", ["Content-Type": "image/jpeg", "Content-Length": String(limit + 1)]) }
        do { _ = try await client.coverData(for: "https://poster.test/declared-large"); throw CheckFailure(message: "Declared oversized image accepted") }
        catch LibreTVError.invalidResponse {}
        StubProtocol.handler = { _ in (200, String(repeating: "x", count: limit + 1), ["Content-Type": "image/jpeg"]) }
        do { _ = try await client.coverData(for: "https://poster.test/streamed-large"); throw CheckFailure(message: "Streamed oversized image accepted") }
        catch LibreTVError.invalidResponse {}
        StubProtocol.handler = { _ in (200, String(repeating: "x", count: limit), ["Content-Type": "image/jpeg"]) }
        let data = try await client.coverData(for: "https://poster.test/maximum")
        try expect(data.count == limit, "An image exactly at the 5 MiB boundary should be accepted")
    }

    @MainActor static func coverSessionExpiry() async throws {
        let client = try makeClient()
        defer { client.disconnect() }
        StubProtocol.handler = { request in
            if request.url?.path == "/api/auth" {
                return (200, #"{"success":true}"#, ["Set-Cookie": "ltv_session=fake-test-session; HttpOnly; Path=/"])
            }
            return (200, "image", ["Content-Type": "image/png"])
        }
        try await client.login(password: "fake")
        _ = try await client.coverData(for: "https://poster.test/cached")
        StubProtocol.handler = { _ in (401, "private upstream response", [:]) }
        do { _ = try await client.coverData(for: "https://poster.test/expired"); throw CheckFailure(message: "Unauthorized cover accepted") }
        catch LibreTVError.unauthorized {}
        try expect(try client.playbackRequest(for: "https://media.test/play").cookies.isEmpty,
                   "Unauthorized cover must clear the login session")
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            try expect(request.value(forHTTPHeaderField: "Cookie") == nil, "Expired cover request must not retain a cookie")
            return (200, "replacement", ["Content-Type": "image/png"])
        }
        let data = try await client.coverData(for: "https://poster.test/cached")
        try expect(data == Data("replacement".utf8) && requests == 1, "Session expiry must also clear previously cached images")
    }

    @MainActor static func coverRedirectAndCancellation() async throws {
        let client = try makeClient()
        defer { client.disconnect() }
        StubProtocol.handler = { _ in (302, "", ["Location": "https://untrusted.example.test", "Content-Type": "image/png"]) }
        do { _ = try await client.coverData(for: "https://poster.test/redirect"); throw CheckFailure(message: "Redirected cover accepted") }
        catch LibreTVError.redirectBlocked {}
        StubProtocol.handler = { _ in nil }
        let task = Task { try await client.coverData(for: "https://poster.test/slow") }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; throw CheckFailure(message: "Cover cancellation ignored") }
        catch is CancellationError {}
    }

    @MainActor static func coverConcurrentSessionTransition(relogin: Bool) async throws {
        var pending: StreamingProtocol?
        var requests = 0
        var logins = 0
        var holdCover = true
        StreamingProtocol.queue.sync {
            StreamingProtocol.handler = { response in
                requests += 1
                switch response.request.url?.path {
                case "/api/auth":
                    logins += 1
                    response.complete(status: 200, body: #"{"success":true}"#,
                                      headers: ["Set-Cookie": "ltv_session=fake-session-\(logins); HttpOnly; Path=/"])
                case "/api/status": response.complete(status: 401)
                default:
                    if holdCover {
                        response.headers(status: 200, headers: ["Content-Type": "image/png"])
                        response.client?.urlProtocol(response, didLoad: Data("old-session".utf8))
                        pending = response
                    } else {
                        response.complete(status: 200, body: "fresh-image", headers: ["Content-Type": "image/png"])
                    }
                }
            }
        }
        let client = LibreTVClient(server: try ServerAddress("http://nas.example.test:8899"),
                                  protocolClasses: [StreamingProtocol.self])
        defer {
            client.disconnect()
            StreamingProtocol.queue.sync { StreamingProtocol.handler = nil }
        }
        try await client.login(password: "fake")
        let task = Task { try await client.coverData(for: "https://poster.test/pending") }
        for _ in 0..<200 {
            if StreamingProtocol.queue.sync(execute: { pending != nil }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(StreamingProtocol.queue.sync { pending != nil }, "Image fixture must reach the pending stream before changing session")
        if relogin {
            try await client.login(password: "fake")
        } else {
            do { _ = try await client.status(); throw CheckFailure(message: "401 status accepted") }
            catch LibreTVError.unauthorized {}
        }
        StreamingProtocol.queue.sync {
            holdCover = false
            if let pending { pending.client?.urlProtocolDidFinishLoading(pending) }
        }
        do { _ = try await task.value; throw CheckFailure(message: "Old-session image returned after authentication changed") }
        catch is CancellationError {}
        let before = StreamingProtocol.queue.sync { requests }
        let fresh = try await client.coverData(for: "https://poster.test/pending")
        try expect(fresh == Data("fresh-image".utf8) && StreamingProtocol.queue.sync { requests == before + 1 },
                   "Old-session image must not repopulate the cleared cache")
    }

    @MainActor static func staleUnauthorizedPreservesNewLogin(cover: Bool) async throws {
        var pending: StreamingProtocol?
        var logins = 0
        StreamingProtocol.queue.sync {
            StreamingProtocol.handler = { response in
                if response.request.url?.path == "/api/auth" {
                    logins += 1
                    response.complete(status: 200, body: #"{"success":true}"#,
                                      headers: ["Set-Cookie": "ltv_session=fake-session-\(logins); HttpOnly; Path=/"])
                } else {
                    pending = response
                }
            }
        }
        let client = LibreTVClient(server: try ServerAddress("http://nas.example.test:8899"),
                                  protocolClasses: [StreamingProtocol.self])
        defer {
            client.disconnect()
            StreamingProtocol.queue.sync { StreamingProtocol.handler = nil }
        }
        try await client.login(password: "fake")
        let task = Task {
            if cover { _ = try await client.coverData(for: "https://poster.test/pending") }
            else { _ = try await client.status() }
        }
        for _ in 0..<200 {
            if StreamingProtocol.queue.sync(execute: { pending != nil }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(StreamingProtocol.queue.sync { pending != nil }, "Old request must be pending before the replacement login")
        try await client.login(password: "fake")
        StreamingProtocol.queue.sync { pending?.complete(status: 401) }
        var cancelled = false
        do { try await task.value }
        catch is CancellationError { cancelled = true }
        catch LibreTVError.unauthorized {}
        let cookies = try client.playbackRequest(for: "https://media.test/play").cookies
        try expect(cookies.first?.value == "fake-session-2", "An old request's late 401 must not erase the new login cookie")
        try expect(cancelled, "A response from an old session must be cancelled before authentication handling")
    }

    @MainActor static func makeClient() throws -> LibreTVClient {
        LibreTVClient(server: try ServerAddress("http://nas.example.test:8899"), protocolClasses: [StubProtocol.self])
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

struct CheckFailure: Error { let message: String }

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, [String: String])?)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let (status, body, headers) = try Self.handler?(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class StreamingProtocol: URLProtocol {
    static let queue = DispatchQueue(label: "libretv.tests.streaming")
    static var handler: ((StreamingProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.queue.async { Self.handler?(self) } }
    override func stopLoading() {}

    func headers(status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func complete(status: Int, body: String = "", headers: [String: String] = [:]) {
        self.headers(status: status, headers: headers)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

#if LIBRETV_SELF_CHECK
@main struct CoreSelfCheck {
    @MainActor static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("server address", { try ContractChecks.serverAddress() }),
            ("request contract and partial source success", ContractChecks.requestContract),
            ("source and query boundaries", ContractChecks.sourceBoundaries),
            ("sanitized API errors", ContractChecks.errorsAreSanitized),
            ("proxy URLs and isolated cookies", ContractChecks.proxyAndCookies),
            ("configured source and result filtering", ContractChecks.sourceFiltering),
            ("NAS query decoding preserves plus", ContractChecks.queryPlusEncoding),
            ("blocked API redirects", ContractChecks.redirectsAreBlocked),
            ("request cancellation", ContractChecks.cancellation),
            ("recommendation routes", ContractChecks.recommendationEndpoints),
            ("recommendation filtering", ContractChecks.recommendationFiltering),
            ("anime weekday ordering", ContractChecks.animeOrdering),
            ("cover proxy and private cache", ContractChecks.coverProxyAndCache),
            ("cover URL and MIME validation", ContractChecks.coverValidation),
            ("cover byte limit", ContractChecks.coverSizeLimit),
            ("cover session expiry", ContractChecks.coverSessionExpiry),
            ("cover redirect and cancellation", ContractChecks.coverRedirectAndCancellation),
            ("cover completing after session expiry", { try await ContractChecks.coverConcurrentSessionTransition(relogin: false) }),
            ("cover completing after new login", { try await ContractChecks.coverConcurrentSessionTransition(relogin: true) }),
            ("stale cover 401 preserves new login", { try await ContractChecks.staleUnauthorizedPreservesNewLogin(cover: true) }),
            ("stale JSON 401 preserves new login", { try await ContractChecks.staleUnauthorizedPreservesNewLogin(cover: false) })
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(checks.count) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
#else
final class LibreTVCoreTests: XCTestCase {
    func testServerAddress() throws { try ContractChecks.serverAddress() }
    @MainActor func testRequestContract() async throws { try await ContractChecks.requestContract() }
    @MainActor func testSourceBoundaries() async throws { try await ContractChecks.sourceBoundaries() }
    @MainActor func testSanitizedErrors() async throws { try await ContractChecks.errorsAreSanitized() }
    @MainActor func testProxyAndCookies() async throws { try await ContractChecks.proxyAndCookies() }
    @MainActor func testSourceFiltering() async throws { try await ContractChecks.sourceFiltering() }
    @MainActor func testQueryPlusEncoding() async throws { try await ContractChecks.queryPlusEncoding() }
    @MainActor func testRedirects() async throws { try await ContractChecks.redirectsAreBlocked() }
    @MainActor func testCancellation() async throws { try await ContractChecks.cancellation() }
    @MainActor func testRecommendationEndpoints() async throws { try await ContractChecks.recommendationEndpoints() }
    @MainActor func testRecommendationFiltering() async throws { try await ContractChecks.recommendationFiltering() }
    @MainActor func testAnimeOrdering() async throws { try await ContractChecks.animeOrdering() }
    @MainActor func testCoverProxyAndCache() async throws { try await ContractChecks.coverProxyAndCache() }
    @MainActor func testCoverValidation() async throws { try await ContractChecks.coverValidation() }
    @MainActor func testCoverSizeLimit() async throws { try await ContractChecks.coverSizeLimit() }
    @MainActor func testCoverSessionExpiry() async throws { try await ContractChecks.coverSessionExpiry() }
    @MainActor func testCoverRedirectAndCancellation() async throws { try await ContractChecks.coverRedirectAndCancellation() }
    @MainActor func testCoverConcurrentSessionExpiry() async throws { try await ContractChecks.coverConcurrentSessionTransition(relogin: false) }
    @MainActor func testCoverConcurrentSessionReplacement() async throws { try await ContractChecks.coverConcurrentSessionTransition(relogin: true) }
    @MainActor func testStaleCoverUnauthorizedPreservesNewLogin() async throws { try await ContractChecks.staleUnauthorizedPreservesNewLogin(cover: true) }
    @MainActor func testStaleJSONUnauthorizedPreservesNewLogin() async throws { try await ContractChecks.staleUnauthorizedPreservesNewLogin(cover: false) }
}
#endif
