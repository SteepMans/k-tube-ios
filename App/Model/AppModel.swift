import Combine
import Foundation
import SwiftUI
import UIKit

enum Route: Hashable {
    case channel(String)
    case playlist(String)
    case localPlaylist(String)
    case history
    case watchLater
    case favourites
    case savedPlaylists
    case downloads
    case settings
    case manageSubscriptions
    case search(String)
    case accountPlaylist(String)
    case accountHistory
}

@MainActor
final class AppModel: ObservableObject {
    let store: Store
    let gateway = GatewayService.shared
    let innertube: Innertube
    let streams: Streams
    let services: Services
    let account: Account
    @Published var profile: Account.Profile?
    private(set) var player: PlayerModel!
    private(set) var downloads: Downloads!

    @Published var hasKey: Bool
    @Published var tab: StartTab
    @Published var homePath = NavigationPath()
    @Published var shortsPath = NavigationPath()
    @Published var subsPath = NavigationPath()
    @Published var libraryPath = NavigationPath()
    @Published var showWatch = false
    @Published var toast: String?
    @Published var gatewayNotice: String?
    @Published var subsFeed: [VideoItem] = []
    @Published var subsFeedLoading = false
    @Published var subsFeedUpdated: Date?
    /// A video waiting for the "new playlist" dialog.
    @Published var addToPlaylistTarget: VideoItem?

    /// Launch options for the screenshots in CI (debug builds only).
    let demoScreen: String?

    private var toastTask: Task<Void, Never>?
    private var storeChanges: AnyCancellable?
    private var noticeSeen = 0

    init() {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        let direct = args.contains("-ktubeDirect")
        demoScreen = args.firstIndex(of: "-ktubeScreen").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        #else
        let direct = false
        demoScreen = nil
        #endif
        let st = Store(ephemeral: direct)
        store = st
        let token = Keychain.get("token") ?? ""
        let gwURL = Keychain.get("gateway") ?? ""
        let g = GatewayService.shared
        g.configure(token: token, gatewayURL: gwURL, direct: direct)
        g.start()
        let it = Innertube(http: g, hl: st.settings.hl, gl: st.settings.gl)
        innertube = it
        streams = Streams(innertube: it)
        services = Services(http: g)
        let storedAccount = Keychain.get("google").flatMap { try? JSONDecoder().decode(Account.Stored.self, from: Data($0.utf8)) }
        account = Account(innertube: it, stored: direct ? nil : storedAccount) { s in
            let text = s.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            Keychain.set("google", text)
        }
        profile = account.profile
        hasKey = g.isConfigured
        tab = st.settings.startTab
        player = PlayerModel(app: self)
        downloads = Downloads(app: self)
        ImageLoader.shared.http = g
        // views read the library and settings through the app model: its changes redraw them
        storeChanges = st.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        watchNotices()
        #if DEBUG
        if direct { seedDemo() }
        #endif
    }

    // MARK: key

    func saveKey(token: String, gatewayURL: String) async throws -> Gateway.Info {
        let old = gateway.config.get
        gateway.configure(token: token, gatewayURL: gatewayURL, direct: false)
        do {
            let info = try await gateway.info()
            guard info.proxy else { throw KTubeError("Для этого ключа прокси YouTube на шлюзе выключен. Обратитесь к тому, кто выдал ключ.") }
            Keychain.set("token", token)
            Keychain.set("gateway", gatewayURL)
            hasKey = true
            return info
        } catch {
            gateway.configure(token: old.token, gatewayURL: old.gatewayURL, direct: old.direct)
            throw error
        }
    }

    func forgetKey() {
        Keychain.set("token", nil)
        Keychain.set("gateway", nil)
        gateway.configure(token: "", gatewayURL: "", direct: false)
        player.stop()
        hasKey = false
    }

    // MARK: messages

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    func show(_ error: Error) { show(error.localizedDescription) }

    private func watchNotices() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let (serial, text, _) = self.gateway.notice.get
                if serial != self.noticeSeen {
                    self.noticeSeen = serial
                    self.show("Шлюз: \(text)")
                }
            }
        }
    }

    func applyRegion() {
        innertube.setRegion(hl: store.settings.hl, gl: store.settings.gl)
    }

    // MARK: navigation

    func push(_ r: Route) {
        if showWatch { showWatch = false }
        switch tab {
        case .home: homePath.append(r)
        case .shorts: shortsPath.append(r)
        case .subscriptions: subsPath.append(r)
        case .library: libraryPath.append(r)
        }
    }

    func play(_ v: VideoItem, queue: [VideoItem] = [], playlistId: String? = nil, start: Double? = nil) {
        player.load(v, queue: queue, playlistId: playlistId, start: start)
        showWatch = true
    }

    /// youtube.com links, youtu.be, ktube://open?url=..., ktube://gateway?... (key links, also the older tgeshka:// form).
    func open(url: URL) {
        let s = url.absoluteString
        if s.hasPrefix("tgeshka://gateway") || s.hasPrefix("ktube://gateway") {
            pendingKeyLink = s
            return
        }
        var link = s
        if s.hasPrefix("ktube://open"), let u = URLCoding.query(s)["url"] { link = u }
        openLink(link)
    }

    @Published var pendingKeyLink: String?

    func openLink(_ link: String) {
        Task {
            do {
                switch try await innertube.resolve(link) {
                case .video(let id, let start): play(VideoItem(id: id), start: start.map(Double.init))
                case .channel(let id): push(.channel(id))
                case .playlist(let id): push(.playlist(id))
                }
            } catch {
                show(error)
            }
        }
    }

    // MARK: library helpers

    /// Bindings for views ($app.settings): the store itself is a constant reference.
    var settings: AppSettings {
        get { store.settings }
        set { store.settings = newValue }
    }

    var library: Library {
        get { store.library }
        set { store.library = newValue }
    }

    var watchedIds: Set<String> { store.library.watchedIds }

    func filtered(_ items: [Item]) -> [Item] {
        store.settings.filter(items, watched: watchedIds)
    }

    func toggleSubscribe(_ c: ChannelItem) {
        let was = store.library.isSubscribed(c.id)
        store.library.toggleSubscription(c)
        show(was ? "Вы отписались от «\(c.name)»" : "Подписка на «\(c.name)» оформлена")
        if !was { Task { await refreshSubsFeed(force: true) } }
        // signed in: the subscription goes to the YouTube account too
        if account.signedIn {
            Task {
                do { try await account.subscribe(c.id, !was) } catch { show("Аккаунт YouTube: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: account

    func accountChanged() {
        profile = account.signedIn ? account.profile : nil
    }

    func signOut() {
        account.signOut()
        profile = nil
        show("Вы вышли из аккаунта YouTube")
    }

    /// Copies the account's subscriptions into the local list.
    func syncSubscriptions() async {
        do {
            let chans = try await account.subscribedChannels()
            let n = store.library.merge(subscriptions: chans)
            show("Подписки аккаунта: \(chans.count), новых здесь: \(n)")
            await refreshSubsFeed(force: true)
        } catch {
            show(error)
        }
    }

    /// Brings the account's watch history and recent searches into the local history.
    func syncHistory() async {
        do {
            let entries = try await account.historyEntries(maxPages: 4)
            let n = store.library.merge(history: entries)
            if let searches = try? await account.searchHistory() {
                for q in searches.reversed() where !store.library.searchHistory.contains(q) { store.library.searchHistory.append(q) }
            }
            show("История аккаунта: новых записей \(n)")
        } catch {
            show(error)
        }
    }

    /// Marks a video watched (full bar) or unwatched; kept in the local history.
    func setWatched(_ v: VideoItem, _ watched: Bool) {
        guard store.settings.historyEnabled else {
            show("История на паузе. Включите её в Библиотеке, чтобы отмечать видео")
            return
        }
        store.library.setWatched(v, watched)
        show(watched ? "Отмечено как просмотренное" : "Отметка о просмотре снята")
    }

    func toggleWatchLater(_ v: VideoItem) {
        let was = store.library.isInWatchLater(v.id)
        store.library.toggleWatchLater(v)
        show(was ? "Убрано из «Смотреть позже»" : "Добавлено в «Смотреть позже»")
    }

    func toggleFavourite(_ v: VideoItem) {
        let was = store.library.isFavourite(v.id)
        store.library.toggleFavourite(v)
        show(was ? "Убрано из избранного" : "Добавлено в избранное")
    }

    func blockChannel(id: String?, name: String) {
        guard let id, !id.isEmpty else { return }
        store.settings.blockedChannels[id] = name
        show("Канал «\(name)» скрыт из лент")
    }

    // MARK: subscriptions feed

    /// New videos of the subscribed channels from their RSS feeds (eight at a time), newest first.
    func refreshSubsFeed(force: Bool = false) async {
        if subsFeedLoading { return }
        if !force, let at = subsFeedUpdated, Date().timeIntervalSince(at) < 15 * 60, !subsFeed.isEmpty { return }
        let subs = store.library.subscriptions
        guard !subs.isEmpty else { subsFeed = []; return }
        subsFeedLoading = true
        defer { subsFeedLoading = false }
        let services = self.services
        var all: [VideoItem] = []
        await withTaskGroup(of: [VideoItem].self) { group in
            var it = subs.makeIterator()
            func addNext() -> Bool {
                guard let s = it.next() else { return false }
                let ch = s.channel
                group.addTask {
                    guard var items = try? await services.channelRSS(ch.id).1 else { return [] }
                    for i in items.indices {
                        items[i].channelAvatar = ch.avatar
                        if items[i].channelName.isEmpty { items[i].channelName = ch.name }
                    }
                    return items
                }
                return true
            }
            for _ in 0..<8 { if !addNext() { break } }
            while let r = await group.next() {
                all += r
                _ = addNext()
            }
        }
        var seen = Set<String>()
        subsFeed = all.filter { seen.insert($0.id).inserted }.sorted { ($0.publishedTs ?? 0) > ($1.publishedTs ?? 0) }
        subsFeedUpdated = Date()
    }

    // MARK: demo (debug)

    #if DEBUG
    private func seedDemo() {
        guard store.library.history.isEmpty else { return }
        let demo: [(String, String, String, String)] = [
            ("dQw4w9WgXcQ", "Rick Astley - Never Gonna Give You Up", "Rick Astley", "UCuAXFkgsw1L7xaCfnd5JJOw"),
            ("jfKfPfyJRdk", "lofi hip hop radio", "Lofi Girl", "UCSJ4gkVC6NrvII8umztf0Ow"),
            ("aqz-KE-bpKQ", "Big Buck Bunny 60fps 4K", "Blender", "UCSMOQeBJ2RAnuFungnQOxLg"),
        ]
        var lib = Library()
        for (i, d) in demo.enumerated() {
            var v = VideoItem(id: d.0, title: d.1, channelName: d.2, channelId: d.3)
            v.durationSecs = 600
            v.durationText = "10:00"
            lib.recordWatch(v, position: Double(120 * (i + 1)), duration: 600, at: Format.now() - 3600 * (i + 1))
        }
        lib.toggleWatchLater(VideoItem(id: "aqz-KE-bpKQ", title: "Big Buck Bunny 60fps 4K", channelName: "Blender", channelId: "UCSMOQeBJ2RAnuFungnQOxLg"))
        lib.toggleSubscription(ChannelItem(id: "UCSJ4gkVC6NrvII8umztf0Ow", name: "Lofi Girl"))
        lib.toggleSubscription(ChannelItem(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"))
        lib.recordSearch("котики")
        lib.recordSearch("рецепт борща")
        store.library = lib
    }
    #endif
}
