import AVFoundation
import SwiftUI

/// The preview of a long-pressed card: the video plays muted in low quality, with a progress line and time left.
/// Only one exists at a time (the system shows one menu); it stops as soon as the menu closes. Stream links are
/// cached by Streams, so a repeat press starts quickly. While the main player plays, only the cover is shown:
/// the key's speed limit is better spent on the video being watched.
struct PressPreview: View {
    @EnvironmentObject var app: AppModel
    let video: VideoItem
    @StateObject private var model = PressPreviewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            Thumbnail(video: video, corner: 0)
            if model.started {
                PreviewPlayerLayer(player: model.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .transition(.opacity)
            }
            if model.duration > 0 {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Text(Format.duration(max(0, model.duration - model.time)))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                    GeometryReader { g in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: g.size.width * min(1, model.time / model.duration))
                    }
                    .frame(height: 3)
                }
            }
        }
        .frame(width: 360, height: 202.5)
        .task { await start() }
        .onDisappear { model.stop() }
    }

    private func start() async {
        guard app.store.settings.pressPreview, !(app.player?.isPlaying ?? false), !video.isLive, !video.isUpcoming else { return }
        // a quick press is often just for the menu actions: wait a little before using the network
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled, let info = try? await app.streams.resolve(video.id), let hls = info.hlsURL else { return }
        guard !Task.isCancelled else { return }
        let playable = info.variants.filter { HLS.playable($0.codecs, av1: false) }
        let low = playable.filter { $0.height <= 360 }.max { $0.bandwidth < $1.bandwidth }
            ?? playable.min { $0.bandwidth < $1.bandwidth }
        guard let url = app.gateway.server.masterURL(hls, quality: low?.qualityClass ?? 0, fps: low?.fps ?? 0, audio: nil, av1: false) else { return }
        let length = Double(info.lengthSecs)
        model.play(url, at: length > 60 ? length * 0.1 : 0, duration: length)
    }
}

@MainActor
final class PressPreviewModel: ObservableObject {
    let player = AVPlayer()
    @Published var started = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    private var observer: Any?

    func play(_ url: URL, at start: Double, duration: Double) {
        self.duration = duration
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 8
        item.preferredPeakBitRate = 1_000_000
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: item)
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                if !self.started, self.player.timeControlStatus == .playing {
                    withAnimation { self.started = true }
                }
            }
        }
        player.play()
    }

    /// Stops playback and drops the item: the local server closes the preview's gateway connections.
    func stop() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        started = false
    }
}

private struct PreviewPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        v.playerLayer.player = player
    }
}
