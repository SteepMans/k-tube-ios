import AVFoundation
import SwiftUI

/// Shorts in a vertical pager: each one loops, swiping moves to the next.
/// The next and the previous short are prepared ahead (streams resolved, the player item buffering at the lowest
/// quality), so a swipe starts the picture right away; players are kept for those three and reused.
@MainActor
final class ShortsModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var current: String?
    @Published var error: String?
    @Published var loading = false
    @Published var meta: [String: WatchInfo] = [:]
    /// the player on screen
    @Published private(set) var player = AVQueuePlayer()
    private var continuation: String?
    private var loadingMore = false

    // AVFoundation objects stay on the main actor; the struct only crosses the look-ahead task
    private struct Slot: @unchecked Sendable {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let info: StreamInfo
    }
    private var slots: [String: Slot] = [:]
    private var preparing: [String: Task<Slot?, Never>] = [:]
    private var startObservation: NSKeyValueObservation?

    /// Time from showing a short to its first played frame, the last ones (ms): in the settings.
    static let startTimes = Locked<[Int]>([])

    func load(app: AppModel) async {
        guard items.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        let seed = app.store.library.history.first { $0.video.isShort }?.video.id
        do {
            let (list, cont) = try await app.innertube.shortsFeed(token: nil, seed: seed)
            items = list
            continuation = cont
            current = list.first?.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    func more(app: AppModel) async {
        guard let t = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if case let (list, cont)? = try? await app.innertube.shortsFeed(token: t, seed: nil) {
            let seen = Set(items.map(\.id))
            items += list.filter { !seen.contains($0.id) }
            continuation = cont
        }
    }

    /// Streams and a buffering player for one short (shared by the swipe and the look-ahead).
    private func prepare(_ id: String, app: AppModel) async -> Slot? {
        if let s = slots[id] { return s }
        if let t = preparing[id] { return await t.value }
        let task = Task<Slot?, Never> { @MainActor in
            guard let info = try? await app.streams.resolve(id, client: app.store.settings.playbackClient),
                  let hls = info.hlsURL,
                  let url = app.gateway.server.masterURL(hls, quality: 0, fps: 0, audio: nil, av1: app.player.deviceAV1) else { return nil }
            let item = AVPlayerItem(url: url)
            // start on the first listed quality (YouTube lists the lowest first) and climb, with a short buffer
            item.startsOnFirstEligibleVariant = true
            item.preferredForwardBufferDuration = 4
            let p = AVQueuePlayer()
            p.automaticallyWaitsToMinimizeStalling = false
            let slot = Slot(player: p, looper: AVPlayerLooper(player: p, templateItem: item), info: info)
            return slot
        }
        preparing[id] = task
        let slot = await task.value
        preparing[id] = nil
        if let slot { slots[id] = slot }
        return slot
    }

    func play(_ id: String, app: AppModel) async {
        let started = Date()
        for s in slots.values { s.player.pause() }
        if meta[id] == nil {
            Task { if let w = try? await app.innertube.watchNext(id) { meta[id] = w } }
        }
        guard let slot = await prepare(id, app: app), current == id else {
            if current == id, slots[id] == nil { app.show("Не удалось открыть шорт") }
            return
        }
        player = slot.player
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        startObservation = slot.player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            guard p.timeControlStatus == .playing else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Task { @MainActor in
                guard let self, self.startObservation != nil else { return }
                self.startObservation = nil
                ShortsModel.startTimes.with { $0.append(ms); if $0.count > 20 { $0.removeFirst($0.count - 20) } }
            }
        }
        slot.player.play()
        if app.store.settings.historyEnabled {
            let info = slot.info
            var v = VideoItem(id: id, title: info.title, thumbnail: Thumbs.short(id), channelName: info.author, channelId: info.channelId)
            v.isShort = true
            app.store.library.recordWatch(v, position: 0, duration: Double(info.lengthSecs))
        }
        lookAhead(around: id, app: app)
    }

    /// Prepare the neighbours, drop players further away.
    private func lookAhead(around id: String, app: AppModel) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let keep = Set([i - 1, i, i + 1, i + 2].filter { items.indices.contains($0) }.map { items[$0].id })
        for (k, s) in slots where !keep.contains(k) {
            s.player.pause()
            s.player.removeAllItems()
            slots[k] = nil
        }
        for k in [i + 1, i - 1].filter({ items.indices.contains($0) }).map({ items[$0].id }) where slots[k] == nil {
            Task { _ = await prepare(k, app: app) }
            if meta[k] == nil { Task { if let w = try? await app.innertube.watchNext(k) { meta[k] = w } } }
        }
    }

    func pause() { player.pause() }

    static var medianStart: Int? {
        let a = startTimes.get.sorted()
        return a.isEmpty ? nil : a[a.count / 2]
    }
}

struct ShortsView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = ShortsModel()
    @State private var paused = false

    var body: some View {
        // the outer reader knows the insets (status bar, tab bar); the pages themselves take the whole screen,
        // the tab bar floats over the video like in YouTube
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            let page = CGSize(width: outer.size.width + insets.leading + insets.trailing,
                              height: outer.size.height + insets.top + insets.bottom)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { v in
                        self.page(v, insets: insets)
                            .frame(width: page.width, height: page.height)
                            .id(v.id)
                            .onAppear { if v.id == model.items.dropLast(3).last?.id { Task { await model.more(app: app) } } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $model.current)
            .scrollIndicators(.hidden)
            .contentMargins(0, for: .scrollContent)
            .frame(width: page.width, height: page.height)
            .background(Color.black)
            .ignoresSafeArea()
            .overlay {
                if model.loading && model.items.isEmpty { ProgressView().tint(.white) }
                if let e = model.error, model.items.isEmpty { ErrorState(text: e) { Task { model.error = nil; await model.load(app: app) } } }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load(app: app) }
        .onChange(of: model.current) { _, id in
            guard let id else { return }
            paused = false
            Task { await model.play(id, app: app) }
        }
        .onAppear {
            app.player.player.pause()
            if let id = model.current, model.player.currentItem == nil { Task { await model.play(id, app: app) } } else if !paused { model.player.play() }
        }
        .onDisappear { model.pause() }
    }

    @ViewBuilder
    private func page(_ v: VideoItem, insets: EdgeInsets) -> some View {
        let w = model.meta[v.id]
        ZStack(alignment: .bottomLeading) {
            Color.black.overlay { RemoteImage(url: v.thumbnail, contentMode: .fill) }.clipped()
            if model.current == v.id {
                PlayerSurface(player: model.player, gravity: .resizeAspectFill)
                    .onTapGesture {
                        if model.player.timeControlStatus == .paused { model.player.play(); paused = false } else { model.player.pause(); paused = true }
                    }
                if paused {
                    Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if let w {
                        Button { if !w.channel.id.isEmpty { app.push(.channel(w.channel.id)) } } label: {
                            HStack(spacing: 8) {
                                Avatar(url: w.channel.avatar, size: 32, name: w.channel.name)
                                Text(w.channel.name).font(.subheadline.bold())
                            }
                        }
                        .buttonStyle(.plain)
                        Text(w.title).font(.subheadline).lineLimit(3)
                    }
                }
                .foregroundStyle(.white)
                Spacer()
                VStack(spacing: 22) {
                    let full = VideoItem(id: v.id, title: w?.title ?? "", channelName: w?.channel.name ?? "", channelId: w?.channel.id)
                    sideButton(app.store.library.isFavourite(v.id) ? "star.fill" : "star", w?.likesText ?? "") { app.toggleFavourite(full) }
                    sideButton("clock", "Позже") { app.toggleWatchLater(full) }
                    ShareLink(item: URL(string: "https://www.youtube.com/shorts/\(v.id)")!) {
                        VStack(spacing: 4) { Image(systemName: "arrowshape.turn.up.right.fill").font(.title2); Text("Поделиться").font(.caption2) }
                    }
                    .foregroundStyle(.white)
                    sideButton("rectangle.expand.vertical", "В плеере") {
                        model.pause()
                        app.play(full)
                    }
                }
            }
            .padding(.leading, 16 + insets.leading)
            .padding(.trailing, 12 + insets.trailing)
            // above the floating tab bar and the home indicator
            .padding(.bottom, insets.bottom + 16)
        }
        .clipped()
    }

    private func sideButton(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2)
                if !text.isEmpty { Text(text).font(.caption2) }
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// An AVPlayerLayer in SwiftUI.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .clear
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }
}
