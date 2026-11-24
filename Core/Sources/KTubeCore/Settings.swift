import Foundation

public enum Theme: String, Codable, Sendable, CaseIterable {
    case system, dark, light
    public var title: String {
        switch self {
        case .system: return "Как в системе"
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        }
    }
}

public enum StartTab: String, Codable, Sendable, CaseIterable {
    case home, shorts, subscriptions, library
    public var title: String {
        switch self {
        case .home: return "Главная"
        case .shorts: return "Shorts"
        case .subscriptions: return "Подписки"
        case .library: return "Библиотека"
        }
    }
}

public enum CaptionSize: String, Codable, Sendable, CaseIterable {
    case small, medium, large, huge
    public var title: String {
        switch self {
        case .small: return "Мелкий"
        case .medium: return "Обычный"
        case .large: return "Крупный"
        case .huge: return "Очень крупный"
        }
    }
    public var points: Double {
        switch self {
        case .small: return 14
        case .medium: return 17
        case .large: return 21
        case .huge: return 26
        }
    }
}

/// Settings of the app. Decoding is tolerant: a key added in a later version takes its default.
public struct AppSettings: Codable, Sendable, Equatable {
    // look
    public var theme: Theme = .dark
    public var accent: String = "9b87f5"
    public var startTab: StartTab = .home
    public var hl: String = "ru"
    public var gl: String = "RU"
    public var gridOnPad: Bool = true

    // playback
    /// 0 = automatic, otherwise the preferred height class (1080, 720, ...)
    public var defaultQuality: Int = 0
    /// on mobile data
    public var cellularQuality: Int = 720
    public var rememberQuality: Bool = true
    public var autoplay: Bool = true
    public var loop: Bool = false
    public var speed: Double = 1
    public var speedPerChannel: Bool = false
    public var channelSpeeds: [String: Double] = [:]
    public var backgroundPlay: Bool = true
    public var autoPiP: Bool = true
    public var audioOnly: Bool = false
    public var originalAudio: Bool = true
    public var resume: Bool = true
    public var seekStep: Int = 10
    public var holdFor2x: Bool = true
    public var playbackClient: Streams.Client = .auto
    public var allowAV1: Bool = true
    public var showHeatmap: Bool = true
    public var seekPreview: Bool = true

    // captions
    public var captionsEnabled: Bool = false
    public var captionsLang: String = "ru"
    public var captionSize: CaptionSize = .medium
    public var captionBackground: Double = 0.6
    public var captionColor: String = "ffffff"

    // SponsorBlock, DeArrow, RYD
    public var sponsorBlock: Bool = true
    public var sbServer: String = "https://sponsor.ajay.app"
    public var sbActions: [String: SegmentAction] = [
        "sponsor": .skip, "selfpromo": .skip, "interaction": .skip, "intro": .mark, "outro": .mark, "preview": .mark,
        "hook": .ignore, "music_offtopic": .skip, "filler": .ignore, "poi_highlight": .mark, "exclusive_access": .mark,
    ]
    public var sbUserId: String = ""
    public var dearrow: Bool = false
    public var dearrowThumbnails: Bool = false
    public var returnDislike: Bool = true

    // less noise
    public var hideShorts: Bool = false
    public var hideLive: Bool = false
    public var hideUpcoming: Bool = false
    public var hideWatched: Bool = false
    public var hideComments: Bool = false
    public var hideRelated: Bool = false
    public var hideDescription: Bool = false
    public var hideChapters: Bool = false
    public var hideAvatars: Bool = false
    public var hideViews: Bool = false
    public var hideExplore: Bool = false
    public var blockedChannels: [String: String] = [:]
    public var blockedKeywords: [String] = []

    // data
    public var historyEnabled: Bool = true
    public var searchHistoryEnabled: Bool = true
    public var liveChatAll: Bool = false
    // added later: decoded with defaults for older files
    public var annotations: Bool = true
    public var ambientGlow: Bool = true
    public var roundThumbnails: Bool = true
    public var captionEdge: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case theme, accent, startTab, hl, gl, gridOnPad, defaultQuality, cellularQuality, rememberQuality, autoplay, loop, speed
        case speedPerChannel, channelSpeeds, backgroundPlay, autoPiP, audioOnly, originalAudio, resume, seekStep, holdFor2x
        case playbackClient, allowAV1, showHeatmap, seekPreview, captionsEnabled, captionsLang, captionSize, captionBackground
        case captionColor, sponsorBlock, sbServer, sbActions, sbUserId, dearrow, dearrowThumbnails, returnDislike, hideShorts
        case hideLive, hideUpcoming, hideWatched, hideComments, hideRelated, hideDescription, hideChapters, hideAvatars
        case hideViews, hideExplore, blockedChannels, blockedKeywords, historyEnabled, searchHistoryEnabled, liveChatAll
        case annotations, ambientGlow, roundThumbnails, captionEdge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T {
            if let x = try? c.decodeIfPresent(T.self, forKey: k) { return x }
            return def
        }
        theme = v(.theme, d.theme); accent = v(.accent, d.accent); startTab = v(.startTab, d.startTab); hl = v(.hl, d.hl)
        gl = v(.gl, d.gl); gridOnPad = v(.gridOnPad, d.gridOnPad); defaultQuality = v(.defaultQuality, d.defaultQuality)
        cellularQuality = v(.cellularQuality, d.cellularQuality); rememberQuality = v(.rememberQuality, d.rememberQuality)
        autoplay = v(.autoplay, d.autoplay); loop = v(.loop, d.loop); speed = v(.speed, d.speed)
        speedPerChannel = v(.speedPerChannel, d.speedPerChannel); channelSpeeds = v(.channelSpeeds, d.channelSpeeds)
        backgroundPlay = v(.backgroundPlay, d.backgroundPlay); autoPiP = v(.autoPiP, d.autoPiP); audioOnly = v(.audioOnly, d.audioOnly)
        originalAudio = v(.originalAudio, d.originalAudio); resume = v(.resume, d.resume); seekStep = v(.seekStep, d.seekStep)
        holdFor2x = v(.holdFor2x, d.holdFor2x); playbackClient = v(.playbackClient, d.playbackClient); allowAV1 = v(.allowAV1, d.allowAV1)
        showHeatmap = v(.showHeatmap, d.showHeatmap); seekPreview = v(.seekPreview, d.seekPreview)
        captionsEnabled = v(.captionsEnabled, d.captionsEnabled); captionsLang = v(.captionsLang, d.captionsLang)
        captionSize = v(.captionSize, d.captionSize); captionBackground = v(.captionBackground, d.captionBackground)
        captionColor = v(.captionColor, d.captionColor); sponsorBlock = v(.sponsorBlock, d.sponsorBlock); sbServer = v(.sbServer, d.sbServer)
        sbActions = d.sbActions.merging(v(.sbActions, [String: SegmentAction]())) { $1 }
        sbUserId = v(.sbUserId, d.sbUserId); dearrow = v(.dearrow, d.dearrow); dearrowThumbnails = v(.dearrowThumbnails, d.dearrowThumbnails)
        returnDislike = v(.returnDislike, d.returnDislike); hideShorts = v(.hideShorts, d.hideShorts); hideLive = v(.hideLive, d.hideLive)
        hideUpcoming = v(.hideUpcoming, d.hideUpcoming); hideWatched = v(.hideWatched, d.hideWatched); hideComments = v(.hideComments, d.hideComments)
        hideRelated = v(.hideRelated, d.hideRelated); hideDescription = v(.hideDescription, d.hideDescription)
        hideChapters = v(.hideChapters, d.hideChapters); hideAvatars = v(.hideAvatars, d.hideAvatars); hideViews = v(.hideViews, d.hideViews)
        hideExplore = v(.hideExplore, d.hideExplore); blockedChannels = v(.blockedChannels, d.blockedChannels)
        blockedKeywords = v(.blockedKeywords, d.blockedKeywords); historyEnabled = v(.historyEnabled, d.historyEnabled)
        searchHistoryEnabled = v(.searchHistoryEnabled, d.searchHistoryEnabled); liveChatAll = v(.liveChatAll, d.liveChatAll)
        annotations = v(.annotations, d.annotations); ambientGlow = v(.ambientGlow, d.ambientGlow)
        roundThumbnails = v(.roundThumbnails, d.roundThumbnails); captionEdge = v(.captionEdge, d.captionEdge)
    }

    /// Categories SponsorBlock is asked for (everything not ignored).
    public var sbCategories: [String] {
        Services.categories.map(\.id).filter { (sbActions[$0] ?? .ignore) != .ignore }
    }

    public func speed(for channelId: String?) -> Double {
        if speedPerChannel, let id = channelId, let s = channelSpeeds[id] { return s }
        return speed
    }

    /// Hides what the user asked to hide in feeds and search.
    public func filter(_ items: [Item], watched: Set<String> = []) -> [Item] {
        let words = blockedKeywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        return items.filter { item in
            switch item {
            case .video(let v):
                if hideShorts && v.isShort { return false }
                if hideLive && v.isLive { return false }
                if hideUpcoming && v.isUpcoming { return false }
                if hideWatched && watched.contains(v.id) { return false }
                if let c = v.channelId, blockedChannels[c] != nil { return false }
                if !v.channelName.isEmpty, blockedChannels.values.contains(v.channelName) { return false }
                let t = v.title.lowercased()
                if words.contains(where: { t.contains($0) }) { return false }
                return true
            case .channel(let c):
                return blockedChannels[c.id] == nil
            case .playlist(let p):
                if let c = p.channelId, blockedChannels[c] != nil { return false }
                return true
            }
        }
    }

    public func filter(_ videos: [VideoItem], watched: Set<String> = []) -> [VideoItem] {
        filter(videos.map(Item.video), watched: watched).compactMap(\.video)
    }

    public static let accents: [(String, String)] = [
        ("9b87f5", "Лаванда"), ("ff0033", "Красный"), ("f0307e", "Розовый"), ("ab47bc", "Фиолетовый"),
        ("3ea6ff", "Синий"), ("00bfa5", "Бирюзовый"), ("2ba640", "Зелёный"), ("ffa000", "Оранжевый"),
    ]

    public static let qualities: [Int] = [0, 2160, 1440, 1080, 720, 480, 360, 240, 144]

    public static func qualityTitle(_ q: Int) -> String { q == 0 ? "Автоматически" : "\(q)p" }

    /// The variant to start with: the preferred class or the closest lower one; nil = automatic.
    public static func pick(_ variants: [Variant], preferred: Int) -> Variant? {
        guard preferred > 0, !variants.isEmpty else { return nil }
        let sorted = variants.sorted { ($0.qualityClass, $0.fps) > ($1.qualityClass, $1.fps) }
        return sorted.first { $0.qualityClass <= preferred } ?? sorted.last
    }
}

public enum Regions {
    public static let languages: [(String, String)] = [("ru", "Русский"), ("en", "English"), ("uk", "Українська"), ("kk", "Қазақша"), ("de", "Deutsch"), ("es", "Español"), ("fr", "Français")]
    public static let regions: [(String, String)] = [("RU", "Россия"), ("KZ", "Казахстан"), ("BY", "Беларусь"), ("UA", "Украина"), ("US", "США"), ("GB", "Великобритания"), ("DE", "Германия"), ("NL", "Нидерланды")]
}
