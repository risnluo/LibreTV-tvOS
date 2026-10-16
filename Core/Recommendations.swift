import Foundation

enum RecommendationCategory: String, CaseIterable, Identifiable, Sendable {
    case movieWeekly, chineseTV, globalTV, chineseVariety, globalVariety, baiduTV
    case popularMovies, popularTV, highRatedMovies, anime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movieWeekly: return "电影周榜"
        case .chineseTV: return "国产剧周榜"
        case .globalTV: return "海外剧周榜"
        case .chineseVariety: return "国内综艺"
        case .globalVariety: return "海外综艺"
        case .baiduTV: return "百度热播剧"
        case .popularMovies: return "热门电影"
        case .popularTV: return "热门剧集"
        case .highRatedMovies: return "豆瓣高分电影"
        case .anime: return "动漫新番"
        }
    }

    var hotListID: String? {
        switch self {
        case .movieWeekly: return "douban_movie_weekly"
        case .chineseTV: return "douban_tv_chinese"
        case .globalTV: return "douban_tv_global"
        case .chineseVariety: return "douban_show_chinese"
        case .globalVariety: return "douban_show_global"
        case .baiduTV: return "baidu_teleplay"
        default: return nil
        }
    }
}

struct RecommendationItem: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let cover: String?
    let rating: String?
    let isTv: Bool?
}

struct RecommendationResponse: Decodable {
    let items: [RecommendationItem]
}

struct AnimeCalendar: Decodable {
    struct Day: Decodable {
        let weekday: Int
        let items: [RecommendationItem]
    }
    let days: [Day]
}
