import AVFoundation
import AVKit
import Foundation
import MediaPlayer
import Network
import SwiftUI
import UIKit
import VideoToolbox

/// Playback: one AVPlayer for the whole app (watch screen, mini player, picture in picture, background audio).
@MainActor
final class PlayerModel: NSObject, ObservableObject {
    unowned let app: AppModel
    let player = AVPlayer()
    let layer = AVPlayerLayer()
    private(set) var pip: AVPictureInPictureController?

    @Published var video: VideoItem?
    @Published var watch: WatchInfo?
    @Published var info: StreamInfo?
    @Published var loading = false
    @Published var error: String?
    @Published var isPlaying = false
    @Published var buffering = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var quality: Variant?
    @Published var audioTrack: String?
    @Published var caption: CaptionTrack?
    @Published var captionText: String?
    @Published var speed: Double = 1
    @Published var segments: [SponsorSegment] = []
    @Published var askSegment: SponsorSegment?
    @Published var highlight: SponsorSegment?
    @Published var queue: [VideoItem] = []
    @Published var playlistTitle: String?
    @Published var votes: Votes?
    @Published var branding: Branding?
    @Published var pipActive = false
    @Published var audioOnly = false
    @Published var loop = false
    @Published var boosted = false
    @Published var playedVariant: String = ""
    @Published var annotations: [Annotation] = []

    private(set) var playlistId: String?
    private var cues: [Cue] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var skipped = Set<String>()
    private var lastSave = Date.distantPast
    private var loadTask: Task<Void, Never>?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var detachedForBackground = false
    private var onCellular = false
    private let pathMonitor = NWPathMonitor()
    let deviceAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    init(app: AppModel) {
        self.app = app
        super.init()
        layer.player = player
        layer.videoGravity = .resizeAspect
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let p = AVPictureInPictureController(playerLayer: layer)
            p?.delegate = self
            pip = p
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus == .playing
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                self?.isPlaying = playing || waiting
                self?.buffering = waiting
                self?.updateNowPlaying()
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let cell = path.usesInterfaceType(.cellular)
            Task { @MainActor in self?.onCellular = cell }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ktube.path"))
        setupRemoteCommands()
        applySettings()
    }

    var settings: AppSettings { app.store.settings }

    func applySettings() {
        pip?.canStartPictureInPictureAutomaticallyFromInline = settings.autoPiP
        loop = settings.loop
        audioOnly = settings.audioOnly
    }

    // MARK: loading

    var variants: [Variant] {
        (info?.variants ?? []).filter { HLS.playable($0.codecs, av1: deviceAV1 && settings.allowAV1) }
    }

    func load(_ v: VideoItem, queue newQueue: [VideoItem] = [], playlistId pl: String? = nil, start: Double? = nil) {
        saveProgress()
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        video = v
        watch = nil
        info = nil
        error = nil
        loading = true
        time = start ?? 0
        duration = Double(v.durationSecs ?? 0)
        segments = []
        annotations = []
        askSegment = nil
        highlight = nil
        votes = nil
        branding = nil
        cues = []
        captionText = nil
        caption = nil
        skipped = []
        boosted = false
        if !newQueue.isEmpty { queue = newQueue } else if pl == nil && !queue.contains(where: { $0.id == v.id }) { queue = [] }
        if pl != nil { playlistId = pl } else if newQueue.isEmpty && !queue.contains(where: { $0.id == v.id }) { playlistId = nil }
        speed = settings.speed(for: v.channelId)
        let id = v.id
        let client = settings.playbackClient
        loadTask = Task { [weak self] in
            guard let self else { return }
            async let streamTask = self.app.streams.resolve(id, client: client)
            async let watchTask = self.app.innertube.watchNext(id, playlistId: self.playlistId)
            do {
                let info = try await streamTask
                if Task.isCancelled || self.video?.id != id { return }
                self.info = info
                self.mergeMetadata(from: info)
                self.startPlayback(info, at: start ?? self.resumePoint(id))
            } catch {
                if Task.isCancelled || self.video?.id != id { return }
                self.loading = false
                self.error = error.localizedDescription
            }
            if let w = try? await watchTask, !Task.isCancelled, self.video?.id == id {
                self.watch = w
                self.mergeMetadata(from: w)
                if let p = w.playlist, !p.items.isEmpty {
                    self.queue = p.items
                    self.playlistTitle = p.title
                }
            }
            await self.loadExtras(id)
        }
    }

    private func resumePoint(_ id: String) -> Double? {
        settings.resume ? app.store.library.resumePosition(id) : nil
    }

    private func mergeMetadata(from i: StreamInfo) {
        guard var v = video else { return }
        if v.title.isEmpty { v.title = i.title }
        if v.channelName.isEmpty { v.channelName = i.author }
        if v.channelId == nil, !i.channelId.isEmpty { v.channelId = i.channelId }
        if v.durationSecs == nil, i.lengthSecs > 0 { v.durationSecs = i.lengthSecs }
        v.isLive = v.isLive || i.isLive
        video = v
        if duration == 0 { duration = Double(i.lengthSecs) }
        recordHistory()
    }

    private func mergeMetadata(from w: WatchInfo) {
        guard var v = video else { return }
        if v.title.isEmpty { v.title = w.title }
        if v.channelName.isEmpty { v.channelName = w.channel.name }
        if v.channelId == nil, !w.channel.id.isEmpty { v.channelId = w.channel.id }
        if v.channelAvatar == nil { v.channelAvatar = w.channel.avatar }
        if v.viewsText == nil { v.viewsText = w.viewsText }
        video = v
        recordHistory()
    }

    private func recordHistory() {
        guard settings.historyEnabled, let v = video, !v.title.isEmpty else { return }
        let old = app.store.library.entry(v.id)
        app.store.library.recordWatch(v, position: old?.position ?? time, duration: max(duration, old?.duration ?? 0))
    }

    private func loadExtras(_ id: String) async {
        let s = settings
        if s.sponsorBlock, !s.sbCategories.isEmpty {
            if let segs = try? await app.services.segments(id, server: s.sbServer, categories: s.sbCategories), video?.id == id {
                segments = segs
                highlight = segs.first { $0.category == "poi_highlight" }
            }
        }
        if s.returnDislike, let v = try? await app.services.votes(id), video?.id == id { votes = v }
        if s.dearrow, let b = await app.services.dearrow(id), video?.id == id { branding = b }
        if s.annotations, let a = try? await Annotations.fetch(id, http: app.gateway), video?.id == id { annotations = a }
    }

    private func startPlayback(_ info: StreamInfo, at start: Double?) {
        if quality == nil || !settings.rememberQuality {
            let pref = onCellular && settings.cellularQuality > 0 ? min(settings.cellularQuality, settings.defaultQuality == 0 ? 99999 : settings.defaultQuality) : settings.defaultQuality
            quality = AppSettings.pick(variants, preferred: pref)
        } else if let q = quality {
            quality = AppSettings.pick(variants, preferred: q.qualityClass)
        }
        if audioTrack == nil || !info.audioTracks.contains(where: { $0.name == audioTrack }) {
            audioTrack = defaultAudio(info)
        }
        buildItem(at: start, autoplay: true)
        if settings.captionsEnabled {
            let lang = settings.captionsLang.lowercased()
            if let c = info.captions.first(where: { $0.lang.lowercased().hasPrefix(lang) && !$0.auto }) ?? info.captions.first(where: { $0.lang.lowercased().hasPrefix(lang) }) {
                selectCaption(c)
            }
        }
    }

    private func defaultAudio(_ info: StreamInfo) -> String? {
        guard info.audioTracks.count > 1 else { return nil }
        if !settings.originalAudio {
            let lang = settings.hl.lowercased()
            if let a = info.audioTracks.first(where: { $0.language.lowercased() == lang || $0.language.lowercased().hasPrefix(lang + "-") }) { return a.name }
        }
        return info.audioTracks.first(where: \.isOriginal)?.name ?? info.audioTracks.first?.name
    }

    /// (Re)creates the player item for the current quality, audio and audio-only mode, at a position.
    func buildItem(at position: Double?, autoplay: Bool) {
        guard let info, let hls = info.hlsURL else { return }
        let server = app.gateway.server
        let av1 = deviceAV1 && settings.allowAV1
        var url: URL?
        if audioOnly {
            if let track = info.audioTracks.first(where: { $0.name == audioTrack }) ?? info.audioTracks.first(where: \.isOriginal) ?? info.audioTracks.first, !track.url.isEmpty {
                url = URL(string: server.mediaURL(HLS.resolve(track.url, base: hls), name: "index.m3u8"))
            } else {
                let lowest = variants.min { $0.bandwidth < $1.bandwidth }
                url = server.masterURL(hls, quality: lowest?.qualityClass ?? 0, fps: lowest?.fps ?? 0, audio: audioTrack, av1: av1)
            }
        } else {
            url = server.masterURL(hls, quality: quality?.qualityClass ?? 0, fps: quality?.fps ?? 0, audio: audioTrack, av1: av1)
        }
        guard let url else { error = "Не удалось подготовить поток"; loading = false; return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        if quality == nil, onCellular, settings.cellularQuality > 0 {
            item.preferredMaximumResolution = CGSize(width: settings.cellularQuality * 16 / 9, height: settings.cellularQuality)
        }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        videoOutput = out
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let failed = it.status == .failed ? PlayerModel.describe(it) : nil
            let ready = it.status == .readyToPlay
            Task { @MainActor in
                guard let self else { return }
                if let failed {
                    self.loading = false
                    self.error = failed
                } else if ready {
                    self.loading = false
                    let d = it.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        player.replaceCurrentItem(with: item)
        if let p = position, p > 1 {
            player.seek(to: CMTime(seconds: p, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        playedVariant = audioOnly ? "только звук" : (quality?.label ?? "авто")
        activateAudioSession()
        if autoplay { player.playImmediately(atRate: Float(speed)) }
        updateNowPlaying(artworkReload: true)
    }

    /// A downloaded video from the device, no network needed.
    func playOffline(_ v: VideoItem, url: URL) {
        saveProgress()
        loadTask?.cancel()
        video = v
        watch = nil
        info = nil
        error = nil
        loading = false
        segments = []
        cues = []
        caption = nil
        captionText = nil
        queue = []
        duration = Double(v.durationSecs ?? 0)
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProgress(finished: true) }
        }
        player.replaceCurrentItem(with: item)
        if let p = resumePoint(v.id) { player.seek(to: CMTime(seconds: p, preferredTimescale: 600)) }
        playedVariant = "с устройства"
        activateAudioSession()
        player.playImmediately(atRate: Float(speed))
        updateNowPlaying(artworkReload: true)
    }

    func stop() {
        saveProgress()
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        video = nil
        watch = nil
        info = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: controls

    func togglePlay() {
        if player.timeControlStatus == .paused {
            if duration > 0, time >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: Float(speed))
        } else {
            player.pause()
            saveProgress()
        }
    }

    func seek(to t: Double) {
        let target = max(0, duration > 0 ? min(t, duration - 0.5) : t)
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(_ delta: Double) { seek(to: time + delta) }

    func setSpeed(_ s: Double) {
        speed = s
        if isPlaying { player.rate = Float(s) }
        if settings.speedPerChannel, let c = video?.channelId {
            app.store.settings.channelSpeeds[c] = s
        } else {
            app.store.settings.speed = s
        }
    }

    /// Hold to play at 2x.
    func boost(_ on: Bool) {
        guard settings.holdFor2x, isPlaying else { if !on { boosted = false }; return }
        boosted = on
        player.rate = on ? 2 : Float(speed)
    }

    func setQuality(_ v: Variant?) {
        quality = v
        let t = time
        buildItem(at: t, autoplay: isPlaying || player.rate > 0 || true)
    }

    func setAudioTrack(_ name: String) {
        audioTrack = name
        buildItem(at: time, autoplay: true)
    }

    func setAudioOnly(_ on: Bool) {
        audioOnly = on
        buildItem(at: time, autoplay: true)
    }

    func selectCaption(_ c: CaptionTrack?) {
        caption = c
        cues = []
        captionText = nil
        guard let c else { return }
        Task {
            guard let r = try? await app.gateway.getOK(c.url), caption == c else { return }
            cues = WebVTT.parse(r.text)
            captionText = WebVTT.text(at: time, in: cues)
        }
    }

    func skipSegment(_ s: SponsorSegment) {
        seek(to: s.end)
        askSegment = nil
        skipped.insert(s.uuid)
        let server = settings.sbServer
        Task { await app.services.viewed(server: server, uuid: s.uuid) }
    }

    // MARK: queue

    var nextVideo: VideoItem? {
        if let v = video, let i = queue.firstIndex(where: { $0.id == v.id }), i + 1 < queue.count { return queue[i + 1] }
        if !queue.isEmpty, let v = video, !queue.contains(where: { $0.id == v.id }) { return queue.first }
        guard settings.autoplay else { return nil }
        let watched = app.watchedIds
        let related = app.store.settings.filter((watch?.related ?? []).compactMap(\.video), watched: [])
        return related.first { !watched.contains($0.id) && !$0.isLive && !$0.isShort } ?? related.first
    }

    var previousVideo: VideoItem? {
        if let v = video, let i = queue.firstIndex(where: { $0.id == v.id }), i > 0 { return queue[i - 1] }
        return nil
    }

    func playNext() {
        guard let n = nextVideo else { return }
        load(n)
    }

    func playPrevious() {
        if time > 5 || previousVideo == nil { seek(to: 0); return }
        if let p = previousVideo { load(p) }
    }

    private func ended() {
        saveProgress(finished: true)
        if loop {
            seek(to: 0)
            player.playImmediately(atRate: Float(speed))
            return
        }
        if let v = video { app.store.library.watched(v.id) }
        let inQueue = video.map { v in queue.contains { $0.id == v.id } } ?? false
        if inQueue || settings.autoplay { playNext() }
    }

    // MARK: ticking

    private func tick(_ t: Double) {
        guard video != nil, t.isFinite else { return }
        time = t
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - duration) > 1 { duration = d }
        }
        if !cues.isEmpty { captionText = WebVTT.text(at: t, in: cues) }
        checkSegments(t)
        if Date().timeIntervalSince(lastSave) > 5, isPlaying { saveProgress() }
    }

    private func checkSegments(_ t: Double) {
        guard !segments.isEmpty else { return }
        var asking: SponsorSegment?
        var muted = false
        for s in segments where t >= s.start && t < s.end - 0.3 {
            let action = settings.sbActions[s.category] ?? .ignore
            if s.action == "mute" {
                muted = action != .ignore && action != .mark
                continue
            }
            guard s.action == "skip", !skipped.contains(s.uuid) else { continue }
            switch action {
            case .skip:
                skipSegment(s)
                app.show("Пропущено: \(Services.category(s.category).name)")
                return
            case .ask:
                asking = s
            default:
                break
            }
        }
        if player.isMuted != muted { player.isMuted = muted }
        if askSegment != asking { askSegment = asking }
    }

    func saveProgress(finished: Bool = false) {
        guard let v = video, settings.historyEnabled, duration > 0 else { return }
        lastSave = Date()
        app.store.library.updatePosition(v.id, position: finished ? duration : time, duration: duration)
    }

    // MARK: background, picture in picture

    func didEnterBackground() {
        saveProgress()
        guard video != nil, !pipActive else { return }
        if settings.backgroundPlay, isPlaying {
            // without a layer the player keeps playing sound in the background
            layer.player = nil
            detachedForBackground = true
        } else if !settings.backgroundPlay {
            player.pause()
        }
    }

    func willEnterForeground() {
        if detachedForBackground {
            layer.player = player
            detachedForBackground = false
        }
        app.gateway.server.restartIfNeeded()
    }

    func startPiP() {
        guard let pip, pip.isPictureInPicturePossible else {
            app.show("Картинка в картинке сейчас недоступна")
            return
        }
        pip.startPictureInPicture()
    }

    private func activateAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [])
        try? s.setActive(true)
    }

    // MARK: screenshot and stats

    func screenshot() -> UIImage? {
        guard let out = videoOutput, let item = player.currentItem else { return nil }
        let t = item.currentTime()
        guard let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return nil }
        let ci = CIImage(cvPixelBuffer: buf)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The player's error with the last entry of its error log (HTTP status and the kind of file), so a report shows where it broke.
    nonisolated static func describe(_ item: AVPlayerItem) -> String {
        var text = item.error?.localizedDescription ?? "Ошибка воспроизведения"
        if let ev = item.errorLog()?.events.last {
            let kind = ev.uri.map { u -> String in
                if u.contains("/hls/") { return "список качеств" }
                if u.contains("index.m3u8") { return "плейлист" }
                return "фрагмент"
            } ?? "файл"
            text += " (\(kind): \(ev.errorStatusCode) \(ev.errorDomain)\(ev.errorComment.map { ", " + $0 } ?? ""))"
        }
        return text
    }

    struct NerdStats {
        var rows: [(String, String)]
    }

    func stats() -> NerdStats {
        var rows: [(String, String)] = []
        rows.append(("Видео", video?.id ?? "-"))
        rows.append(("Клиент", info?.source ?? "-"))
        rows.append(("Качество", playedVariant))
        if let item = player.currentItem {
            let size = item.presentationSize
            rows.append(("Разрешение", size.width > 0 ? "\(Int(size.width))x\(Int(size.height))" : "-"))
            if let e = item.accessLog()?.events.last {
                rows.append(("Битрейт потока", e.indicatedBitrate > 0 ? String(format: "%.2f Мбит/с", e.indicatedBitrate / 1e6) : "-"))
                rows.append(("Скорость сети", e.observedBitrate > 0 ? String(format: "%.2f Мбит/с", e.observedBitrate / 1e6) : "-"))
                rows.append(("Пропущено кадров", String(e.numberOfDroppedVideoFrames)))
                rows.append(("Переключений", String(e.indicatedBitrate > 0 ? item.accessLog()!.events.count : 0)))
                rows.append(("Сбоев загрузки", String(item.errorLog()?.events.count ?? 0)))
            }
            let buffered = item.loadedTimeRanges.map(\.timeRangeValue).first { $0.containsTime(item.currentTime()) }
            if let b = buffered {
                rows.append(("Буфер", String(format: "%.1f с", b.end.seconds - item.currentTime().seconds)))
            }
        }
        if let v = quality ?? variants.first { rows.append(("Кодеки", v.codecs)) }
        let st = app.gateway.stats.get
        rows.append(("Шлюз: соединений", "\(st.active) открыто, \(st.opened) всего, \(st.failed) сбоев"))
        rows.append(("Шлюз: трафик", String(format: "%.1f МБ получено", Double(st.down) / 1_048_576)))
        return NerdStats(rows: rows)
    }

    // MARK: now playing

    private var artwork: MPMediaItemArtwork?
    private var artworkFor: String?

    func updateNowPlaying(artworkReload: Bool = false) {
        guard let v = video else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: branding?.title ?? v.title,
            MPMediaItemPropertyArtist: v.channelName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyIsLiveStream: v.isLive,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artworkFor == v.id { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if artworkReload || artworkFor != v.id {
            artworkFor = v.id
            artwork = nil
            let id = v.id
            let thumb = v.thumbnail
            Task {
                guard let img = await ImageLoader.shared.image(thumb), self.video?.id == id else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.updateNowPlaying()
            }
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.playImmediately(atRate: Float(self?.speed ?? 1)) }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }
    }

    var currentChapter: Chapter? {
        guard let ch = watch?.chapters, !ch.isEmpty else { return nil }
        return ch.last { $0.start <= time + 0.5 }
    }
}

extension PlayerModel: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.pipActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.pipActive = false }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.app.showWatch = true
            completionHandler(true)
        }
    }
}
