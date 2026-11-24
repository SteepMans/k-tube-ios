import Foundation

public struct VideoItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String = ""
    public var thumbnail: String = ""
    public var channelName: String = ""
    public var channelId: String?
    public var channelAvatar: String?
    public var durationText: String?
    public var durationSecs: Int?
    public var viewsText: String?
    public var publishedText: String?
    /// Approximate upload time (unix seconds) from the relative date.
    public var publishedTs: Int?
    public var descriptionSnippet: String?
    public var isLive: Bool = false
    public var isShort: Bool = false
    public var isUpcoming: Bool = false

    public init(id: String, title: String = "", thumbnail: String? = nil, channelName: String = "", channelId: String? = nil) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail ?? Thumbs.video(id)
        self.channelName = channelName
        self.channelId = channelId
    }

    public var watchURL: String { "https://www.youtube.com/watch?v=\(id)" }
}

public struct ChannelItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String = ""
    public var avatar: String?
    public var handle: String?
    public var subscribersText: String?
    public var videoCountText: String?
    public var description: String?

    public init(id: String, name: String = "", avatar: String? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }
}

public struct PlaylistItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String = ""
    public var thumbnail: String?
    public var channelName: String?
    public var channelId: String?
    public var videoCountText: String?
    public var firstVideoId: String?

    public init(id: String, title: String = "") {
        self.id = id
        self.title = title
    }
}

public enum Item: Hashable, Sendable, Identifiable {
    case video(VideoItem)
    case channel(ChannelItem)
    case playlist(PlaylistItem)

    public var id: String {
        switch self {
        case .video(let v): return "v:" + v.id
        case .channel(let c): return "c:" + c.id
        case .playlist(let p): return "p:" + p.id
        }
    }

    public var video: VideoItem? {
        if case .video(let v) = self { return v }
        return nil
    }
}

public struct Page: Sendable {
    public var items: [Item] = []
    public var continuation: String?
    public init(items: [Item] = [], continuation: String? = nil) {
        self.items = items
        self.continuation = continuation
    }
    public var videos: [VideoItem] { items.compactMap(\.video) }
}

public struct ChannelTab: Hashable, Sendable {
    public var title: String
    public var params: String?
    public var selected: Bool
}

public struct ChannelPage: Sendable {
    public var info: ChannelItem
    public var banner: String?
    public var tabs: [ChannelTab]
    public var page: Page
}

public struct PlaylistPage: Sendable {
    public var info: PlaylistItem
    public var description: String?
    public var videos: [VideoItem]
    public var continuation: String?
}

public struct Chapter: Hashable, Sendable, Codable {
    public var title: String
    public var start: Double
    public var thumbnail: String?
    public init(title: String, start: Double, thumbnail: String? = nil) {
        self.title = title
        self.start = start
        self.thumbnail = thumbnail
    }
}

public struct HeatPoint: Hashable, Sendable {
    public var start: Double
    public var duration: Double
    public var intensity: Double
}

public struct WatchPlaylist: Sendable {
    public var id: String
    public var title: String
    public var items: [VideoItem]
}

public struct WatchInfo: Sendable {
    public var id: String
    public var title: String = ""
    public var viewsText: String = ""
    public var dateText: String = ""
    public var isLive: Bool = false
    public var likesText: String?
    public var channel = ChannelItem(id: "")
    public var description: String = ""
    public var related: [Item] = []
    public var relatedContinuation: String?
    public var commentsToken: String?
    /// (Top, Newest) sort tokens of the comments.
    public var commentsSort: (String?, String?) = (nil, nil)
    public var commentCountText: String?
    public var chapters: [Chapter] = []
    public var heatmap: [HeatPoint] = []
    public var playlist: WatchPlaylist?
    /// (Top chat, every message) continuation tokens of a live chat.
    public var liveChat: (String, String)?

    public init(id: String) { self.id = id }
}

public struct Comment: Hashable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var authorId: String?
    public var authorAvatar: String?
    public var text: String
    public var published: String
    public var likes: String
    public var replyCount: String
    public var repliesToken: String?
    public var isCreator: Bool
    public var isVerified: Bool
    public var isPinned: Bool
    public var hearted: Bool
}

public struct CommentPage: Sendable {
    public var comments: [Comment] = []
    public var continuation: String?
    public var countText: String?
    public var sortTopToken: String?
    public var sortNewToken: String?
    public init() {}
}

public struct ChatMessage: Hashable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var text: String
    public var isOwner: Bool
    public var isModerator: Bool
    public var superChat: String?
}

public struct ChatBatch: Sendable {
    public var messages: [ChatMessage] = []
    public var continuation: String?
    public var timeoutMs: Int = 5000
}

/// One quality of an HLS master playlist.
public struct Variant: Hashable, Sendable, Codable {
    public var url: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bandwidth: Int
    public var codecs: String

    /// "1080p60", "720p"
    public var label: String {
        let c = Quality.classOf(width: width, height: height)
        return "\(c)p" + (fps > 30 ? String(fps) : "")
    }
    public var qualityClass: Int { Quality.classOf(width: width, height: height) }
}

public struct AudioTrack: Hashable, Sendable {
    /// NAME of the rendition, shown in the menu
    public var name: String
    public var language: String
    public var isOriginal: Bool
    /// the rendition's media playlist (audio only mode plays it alone)
    public var url: String = ""
}

public struct CaptionTrack: Hashable, Sendable, Codable {
    public var lang: String
    public var name: String
    /// timedtext URL in WebVTT
    public var url: String
    public var auto: Bool
}

public struct Storyboard: Hashable, Sendable {
    public var urlTemplate: String
    public var width: Int
    public var height: Int
    public var count: Int
    public var cols: Int
    public var rows: Int
    public var intervalMs: Int

    /// The sheet URL and the cell for time t (seconds).
    public func frame(at t: Double) -> (url: String, col: Int, row: Int)? {
        guard count > 0, cols > 0, rows > 0 else { return nil }
        let interval = intervalMs > 0 ? Double(intervalMs) / 1000 : 0
        var idx = interval > 0 ? Int(t / interval) : 0
        idx = max(0, min(count - 1, idx))
        let perSheet = cols * rows
        let sheet = idx / perSheet
        let cell = idx % perSheet
        return (urlTemplate.replacingOccurrences(of: "$M", with: String(sheet)), cell % cols, cell / cols)
    }
}

public struct StreamInfo: Sendable {
    public var id: String = ""
    public var title: String = ""
    public var author: String = ""
    public var channelId: String = ""
    public var lengthSecs: Int = 0
    public var viewCount: Int?
    public var description: String = ""
    public var isLive: Bool = false
    public var hlsURL: String?
    public var variants: [Variant] = []
    public var audioTracks: [AudioTrack] = []
    public var captions: [CaptionTrack] = []
    public var storyboard: Storyboard?
    /// "visionos" or "ios"
    public var source: String = ""
    public var thumbnail: String = ""
    public init() {}
}

public enum Quality {
    /// The usual name of a resolution: the shorter side, snapped to the standard steps (portrait and odd sizes).
    public static func classOf(width: Int, height: Int) -> Int {
        let side = min(width, height) > 0 ? min(width, height) : max(width, height)
        let steps = [144, 240, 360, 480, 720, 1080, 1440, 2160, 4320]
        var best = steps[0]
        for s in steps where Double(side) >= Double(s) * 0.85 { best = s }
        return best
    }
}

public enum Thumbs {
    public static func video(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/hqdefault.jpg" }
    public static func short(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/oar2.jpg" }
    public static func maxres(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg" }
}
