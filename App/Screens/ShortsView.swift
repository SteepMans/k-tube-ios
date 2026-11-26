import AVFoundation
import SwiftUI

/// Shorts in a vertical pager with their own player: each one loops, swiping moves to the next.
@MainActor
final class ShortsModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var current: String?
    @Published var error: String?
    @Published var loading = false
    @Published var meta: [String: WatchInfo] = [:]
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var continuation: String?
    private var loadingMore = false

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

    func play(_ id: String, app: AppModel) async {
        player.pause()
        looper = nil
        player.removeAllItems()
        if meta[id] == nil, let w = try? await app.innertube.watchNext(id) { meta[id] = w }
        guard current == id else { return }
        do {
            let info = try await app.streams.resolve(id, client: app.store.settings.playbackClient)
            guard current == id, let hls = info.hlsURL,
                  let url = app.gateway.server.masterURL(hls, quality: 0, fps: 0, audio: nil, av1: app.player.deviceAV1) else { return }
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            player.play()
            if app.store.settings.historyEnabled {
                var v = VideoItem(id: id, title: info.title, thumbnail: Thumbs.short(id), channelName: info.author, channelId: info.channelId)
                v.isShort = true
                app.store.library.recordWatch(v, position: 0, duration: Double(info.lengthSecs))
            }
        } catch {
            app.show(error)
        }
    }

    func pause() { player.pause() }
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
