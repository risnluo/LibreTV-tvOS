import Foundation

struct ServerAddress: Equatable, Sendable {
    let url: URL
    init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, !host.contains("%"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw LibreTVError.invalidServerAddress
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw LibreTVError.invalidServerAddress }
        self.url = url
    }
}

struct SourceConfig: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let name: String
    let url: String
    let detail: String?
    let isAdult: Bool?
    var id: String { key }
}

struct ServerStatus: Decodable, Sendable {
    let passwordRequired: Bool
    let verified: Bool
    let version: String
    let defaultSources: [SourceConfig]
}

struct SearchResponse: Decodable, Sendable {
    let list: [SearchItem]
    let failures: [SourceFailure]
}

struct SearchItem: Decodable, Hashable, Identifiable, Sendable {
    let sourceKey: String
    let sourceName: String
    let vodId: String
    let name: String
    let pic: String?
    let typeName: String?
    let year: String?
    let area: String?
    let remarks: String?
    let sourceUrl: String?
    let isAdult: Bool?
    var id: String { sourceKey + "\u{1f}" + vodId }
}

struct SourceFailure: Decodable, Sendable {
    let sourceKey: String
    let error: String
    let timedOut: Bool?
}

struct VideoDetail: Decodable, Sendable {
    let episodes: [String]
    let videoInfo: VideoInfo
}

struct VideoInfo: Decodable, Sendable {
    let title: String?
    let cover: String?
    let desc: String?
    let typeName: String?
    let year: String?
    let area: String?
    let director: String?
    let actor: String?
    let remarks: String?
    let sourceKey: String
    let sourceName: String
    let sourceUrl: String?
}

struct PlaybackRequest {
    let url: URL
    let cookies: [HTTPCookie]
}

enum LibreTVError: Error, LocalizedError, Equatable {
    case invalidServerAddress, invalidMediaURL, invalidResponse, noSources, unknownSource, emptyQuery
    case unauthorized, wrongPassword, passwordNotConfigured, rateLimited, redirectBlocked
    case timedOut, networkUnavailable, requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress: return "地址不正确。请输入 http:// 或 https:// 开头的服务器地址，不要附带账号、密码或其他路径。"
        case .invalidMediaURL: return "这集的播放地址不受支持，请返回尝试其他片源。"
        case .invalidResponse: return "服务器返回了无法识别的内容，请检查地址或稍后重试。"
        case .noSources: return "服务器没有可用的点播片源，请在家里的 LibreTV 配置片源后重新连接。"
        case .unknownSource: return "这条结果的片源已不可用，请重新搜索。"
        case .emptyQuery: return "请先输入片名。"
        case .unauthorized: return "登录已过期，请重新输入密码。"
        case .wrongPassword: return "密码不正确，请重新输入。"
        case .passwordNotConfigured: return "服务器尚未配置访问密码，请先完成 LibreTV 的密码设置。"
        case .rateLimited: return "登录尝试过多，请等待 10 分钟后再试。"
        case .redirectBlocked: return "服务器要求跳转。请直接填写 LibreTV 的实际地址后重新连接。"
        case .timedOut: return "连接超时，请检查家庭网络或稍后重试。"
        case .networkUnavailable: return "无法连接服务器，请确认 Apple TV 和 NAS 在同一家庭网络，且 LibreTV 正在运行。"
        case .requestFailed(let code): return "服务器暂时无法完成请求（\(code)），请稍后重试或尝试其他片源。"
        }
    }
}
