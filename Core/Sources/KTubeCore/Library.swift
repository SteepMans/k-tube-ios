import Foundation

public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var video: VideoItem
    public var watchedAt: Int
    /// Where playback stopped (seconds) and the video's length, for "continue" and the progress bar.
    public var position: Double
    public var duration: Double
    public var id: String { video.id }

    public init(video: VideoItem, watchedAt: Int, position: Double = 0, duration: Double = 0) {
        self.video = video
        self.watchedAt = watchedAt
        self.position = position
        self.duration = duration
    }

    public var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    public var finished: Bool { duration > 0 && position >= duration - 15 }
}

public struct LocalPlaylist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var videos: [VideoItem]
    public var createdAt: Int

    public init(id: String = UUID().uuidString, name: String, videos: [VideoItem] = [], createdAt: Int = Format.now()) {
        self.id = id
        self.name = name
        self.videos = videos
        self.createdAt = createdAt
    }
}

public struct Subscription: Codable, Hashable, Sendable, Identifiable {
    public var channel: ChannelItem
    public var subscribedAt: Int
    public var id: String { channel.id }

    public init(channel: ChannelItem, subscribedAt: Int = Format.now()) {
        self.channel = channel
        self.subscribedAt = subscribedAt
    }
}

/// Everything the user keeps on the phone: history, watch later, favourites, playlists, subscriptions.
public struct Library: Codable, Sendable, Equatable {
    public static let historyLimit = 5000
    public static let searchLimit = 100

    public var history: [HistoryEntry] = []
    public var searchHistory: [String] = []
    public var watchLater: [VideoItem] = []
    public var favourites: [VideoItem] = []
    public var playlists: [LocalPlaylist] = []
    /// YouTube playlists saved to the library.
    public var savedPlaylists: [PlaylistItem] = []
    public var subscriptions: [Subscription] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case history, searchHistory, watchLater, favourites, playlists, savedPlaylists, subscriptions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        history = (try? c.decodeIfPresent([HistoryEntry].self, forKey: .history)) ?? []
        searchHistory = (try? c.decodeIfPresent([String].self, forKey: .searchHistory)) ?? []
        watchLater = (try? c.decodeIfPresent([VideoItem].self, forKey: .watchLater)) ?? []
        favourites = (try? c.decodeIfPresent([VideoItem].self, forKey: .favourites)) ?? []
        playlists = (try? c.decodeIfPresent([LocalPlaylist].self, forKey: .playlists)) ?? []
        savedPlaylists = (try? c.decodeIfPresent([PlaylistItem].self, forKey: .savedPlaylists)) ?? []
        subscriptions = (try? c.decodeIfPresent([Subscription].self, forKey: .subscriptions)) ?? []
    }

    // MARK: history

    /// Records a watch: moves the video to the top and keeps the newer metadata.
    public mutating func recordWatch(_ video: VideoItem, position: Double, duration: Double, at now: Int = Format.now()) {
        var v = video
        if let old = history.first(where: { $0.video.id == video.id })?.video {
            if v.title.isEmpty { v.title = old.title }
            if v.channelName.isEmpty { v.channelName = old.channelName }
            if v.channelId == nil { v.channelId = old.channelId }
            if v.durationSecs == nil { v.durationSecs = old.durationSecs }
        }
        history.removeAll { $0.video.id == video.id }
        history.insert(HistoryEntry(video: v, watchedAt: now, position: position, duration: duration), at: 0)
        if history.count > Library.historyLimit { history.removeLast(history.count - Library.historyLimit) }
    }

    /// Updates the position of a video already in the history (no reordering).
    public mutating func updatePosition(_ id: String, position: Double, duration: Double) {
        guard let i = history.firstIndex(where: { $0.video.id == id }) else { return }
        history[i].position = position
        if duration > 0 { history[i].duration = duration }
    }

    public func resumePosition(_ id: String) -> Double? {
        guard let e = history.first(where: { $0.video.id == id }), e.position > 10, !e.finished else { return nil }
        return e.position
    }

    public func entry(_ id: String) -> HistoryEntry? { history.first { $0.video.id == id } }

    public var watchedIds: Set<String> { Set(history.filter { $0.finished || $0.progress > 0.8 }.map(\.video.id)) }

    /// Watched to the end or marked so: the bar is full and the thumbnail dimmed.
    public func isWatched(_ id: String) -> Bool { entry(id)?.finished ?? false }

    /// "Mark as watched" puts the position at the end (adding the video to the history
    /// if it was never opened); "unwatched" puts it back to the start.
    public mutating func setWatched(_ video: VideoItem, _ watched: Bool, at now: Int = Format.now()) {
        if let i = history.firstIndex(where: { $0.video.id == video.id }) {
            if watched {
                let known = history[i].duration > 0 ? history[i].duration : Double(video.durationSecs ?? 0)
                history[i].duration = known > 0 ? known : 1
                history[i].position = history[i].duration
            } else {
                history[i].position = 0
            }
        } else if watched {
            let d = Double(video.durationSecs ?? 0)
            recordWatch(video, position: d > 0 ? d : 1, duration: d > 0 ? d : 1, at: now)
        }
    }

    public mutating func removeHistory(_ id: String) { history.removeAll { $0.video.id == id } }

    public mutating func clearHistory() { history.removeAll() }

    public mutating func recordSearch(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        searchHistory.insert(t, at: 0)
        if searchHistory.count > Library.searchLimit { searchHistory.removeLast(searchHistory.count - Library.searchLimit) }
    }

    // MARK: lists

    public func isInWatchLater(_ id: String) -> Bool { watchLater.contains { $0.id == id } }
    public func isFavourite(_ id: String) -> Bool { favourites.contains { $0.id == id } }

    public mutating func toggleWatchLater(_ v: VideoItem) {
        if isInWatchLater(v.id) { watchLater.removeAll { $0.id == v.id } } else { watchLater.insert(v, at: 0) }
    }

    public mutating func toggleFavourite(_ v: VideoItem) {
        if isFavourite(v.id) { favourites.removeAll { $0.id == v.id } } else { favourites.insert(v, at: 0) }
    }

    /// Watch later drops a video once it has been watched to the end.
    public mutating func watched(_ id: String) {
        watchLater.removeAll { $0.id == id }
    }

    @discardableResult
    public mutating func createPlaylist(_ name: String) -> LocalPlaylist {
        let p = LocalPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Новый плейлист" : name)
        playlists.insert(p, at: 0)
        return p
    }

    public mutating func add(_ v: VideoItem, toPlaylist id: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !playlists[i].videos.contains(where: { $0.id == v.id }) else { return }
        playlists[i].videos.append(v)
    }

    public mutating func remove(_ videoId: String, fromPlaylist id: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].videos.removeAll { $0.id == videoId }
    }

    public mutating func renamePlaylist(_ id: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
    }

    public mutating func deletePlaylist(_ id: String) { playlists.removeAll { $0.id == id } }

    public func isSaved(_ playlistId: String) -> Bool { savedPlaylists.contains { $0.id == playlistId } }

    public mutating func toggleSaved(_ p: PlaylistItem) {
        if isSaved(p.id) { savedPlaylists.removeAll { $0.id == p.id } } else { savedPlaylists.insert(p, at: 0) }
    }

    // MARK: subscriptions

    public func isSubscribed(_ channelId: String) -> Bool { subscriptions.contains { $0.channel.id == channelId } }

    public mutating func toggleSubscription(_ c: ChannelItem) {
        if isSubscribed(c.id) { subscriptions.removeAll { $0.channel.id == c.id } } else { subscriptions.insert(Subscription(channel: c), at: 0) }
    }

    /// Adds subscriptions that are not there yet; returns how many were new.
    @discardableResult
    public mutating func merge(subscriptions new: [ChannelItem]) -> Int {
        var added = 0
        for c in new where !c.id.isEmpty && !isSubscribed(c.id) {
            subscriptions.append(Subscription(channel: c))
            added += 1
        }
        return added
    }

    @discardableResult
    public mutating func merge(history new: [HistoryEntry]) -> Int {
        var added = 0
        let have = Set(history.map(\.video.id))
        for e in new where !have.contains(e.video.id) {
            history.append(e)
            added += 1
        }
        history.sort { $0.watchedAt > $1.watchedAt }
        return added
    }
}
