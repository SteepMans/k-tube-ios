import AVFoundation
import AVKit
import SwiftUI

/// Hosts the player's own AVPlayerLayer (the one picture in picture uses).
struct MainPlayerLayer: UIViewRepresentable {
    let layer: AVPlayerLayer

    final class Host: UIView {
        var hosted: AVPlayerLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .black
        v.hosted = layer
        v.layer.addSublayer(layer)
        return v
    }

    func updateUIView(_ v: Host, context: Context) {
        if layer.superlayer !== v.layer {
            v.layer.addSublayer(layer)
            v.hosted = layer
            v.setNeedsLayout()
        }
    }
}

/// The video with its controls: tap to show, double tap to seek, hold for 2x, the seek bar with chapters,
/// SponsorBlock segments and the most replayed graph.
struct PlayerArea: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerModel
    var fullscreen: Bool
    var toggleFullscreen: () -> Void
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var seekFlash: String?
    @State private var showMenu = false
    @State private var showStats = false
    @State private var shot: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if player.audioOnly {
                RemoteImage(url: player.video?.thumbnail, contentMode: .fit).opacity(0.6)
                Label("Только звук", systemImage: "headphones").font(.caption.bold()).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.5), in: Capsule())
            }
            MainPlayerLayer(layer: player.layer).opacity(player.audioOnly ? 0 : 1)
            if let t = player.captionText, !t.isEmpty { captionView(t) }
            gestures
            if app.store.settings.annotations, !player.annotations.isEmpty, !player.audioOnly { AnnotationsLayer() }
            if player.loading || player.buffering { ProgressView().tint(.white).scaleEffect(1.3).allowsHitTesting(false) }
            if let e = player.error {
                VStack(spacing: 10) {
                    Text(e).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Повторить") { if let v = player.video { app.streams.invalidate(v.id); player.load(v) } }.buttonStyle(.borderedProminent)
                }
                .padding()
            }
            if controls && player.error == nil { overlay.transition(.opacity) }
            if let f = seekFlash {
                Text(f).font(.headline).foregroundStyle(.white).padding(10).background(.black.opacity(0.5), in: Capsule()).allowsHitTesting(false)
            }
            if player.boosted {
                VStack { Label("2x", systemImage: "forward.fill").font(.caption.bold()).foregroundStyle(.white).padding(8).background(.black.opacity(0.6), in: Capsule()); Spacer() }
                    .padding(.top, 12).allowsHitTesting(false)
            }
            sponsorButtons
        }
        .animation(.easeInOut(duration: 0.2), value: controls)
        .onAppear { scheduleHide() }
        .sheet(isPresented: $showMenu) { PlayerSettingsSheet(showStats: $showStats, shot: $shot) }
        .sheet(isPresented: $showStats) { StatsSheet() }
        .sheet(item: Binding(get: { shot.map { Shot(image: $0) } }, set: { shot = $0?.image })) { s in ShareSheet(items: [s.image]) }
    }

    private func captionView(_ t: String) -> some View {
        let s = app.store.settings
        return VStack {
            Spacer()
            Text(t)
                .font(.system(size: fullscreen ? s.captionSize.points * 1.3 : s.captionSize.points, weight: .medium))
                .foregroundStyle(Color(hex: s.captionColor))
                .shadow(color: s.captionEdge ? .black : .clear, radius: 0, x: 1, y: 1)
                .shadow(color: s.captionEdge ? .black : .clear, radius: 1.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(s.captionBackground), in: RoundedRectangle(cornerRadius: 4))
                .padding(.bottom, controls ? 56 : 14)
        }
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }

    private var gestures: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { seekBy(-Double(app.store.settings.seekStep)) }
                .onTapGesture { toggleControls() }
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { seekBy(Double(app.store.settings.seekStep)) }
                .onTapGesture { toggleControls() }
        }
        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
            player.boost(pressing)
        })
    }

    private func seekBy(_ d: Double) {
        player.skip(d)
        seekFlash = d > 0 ? "+\(Int(d)) с" : "\(Int(d)) с"
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            seekFlash = nil
        }
    }

    private func toggleControls() {
        controls.toggle()
        if controls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled, player.isPlaying, scrubbing == nil { controls = false }
        }
    }

    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.35).allowsHitTesting(false)
            VStack {
                HStack(spacing: 18) {
                    if !fullscreen {
                        Button { app.showWatch = false } label: { Image(systemName: "chevron.down") }
                    }
                    if fullscreen, let v = player.video {
                        Text(v.title).font(.subheadline.bold()).lineLimit(1)
                    }
                    Spacer()
                    if player.pip != nil {
                        Button { player.startPiP() } label: { Image(systemName: "pip.enter") }
                    }
                    AirPlayButton().frame(width: 26, height: 26)
                    Button { showMenu = true } label: { Image(systemName: "gearshape.fill") }
                }
                .font(.title3)
                .padding(.horizontal, 14).padding(.top, 10)
                Spacer()
                HStack(spacing: 44) {
                    Button { player.playPrevious() } label: { Image(systemName: "backward.end.fill").font(.title2) }
                    Button { player.togglePlay(); scheduleHide() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 42))
                    }
                    Button { player.playNext() } label: { Image(systemName: "forward.end.fill").font(.title2) }
                        .disabled(player.nextVideo == nil)
                }
                Spacer()
                VStack(spacing: 4) {
                    HStack {
                        Text(Format.duration(scrubbing ?? player.time)).monospacedDigit()
                        if let c = player.currentChapter, !app.store.settings.hideChapters {
                            Text("· \(c.title)").lineLimit(1)
                        }
                        Spacer()
                        if player.video?.isLive == true {
                            Text("В ЭФИРЕ").bold().foregroundStyle(.red)
                        } else {
                            Text(Format.duration(player.duration)).monospacedDigit()
                        }
                        Button(action: toggleFullscreen) { Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                            .padding(.leading, 8)
                    }
                    .font(.caption)
                    SeekBar(scrubbing: $scrubbing) { scheduleHide() }
                }
                .padding(.horizontal, 14).padding(.bottom, fullscreen ? 16 : 6)
            }
            .foregroundStyle(.white)
            if let s = scrubbing { previewBubble(s) }
        }
    }

    @ViewBuilder
    private func previewBubble(_ t: Double) -> some View {
        if app.store.settings.seekPreview, let sb = player.info?.storyboard, let f = sb.frame(at: t) {
            VStack {
                Spacer()
                StoryboardFrame(board: sb, url: f.url, col: f.col, row: f.row)
                    .frame(width: 160, height: 160 * CGFloat(sb.height) / CGFloat(max(sb.width, 1)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 1))
                    .padding(.bottom, 64)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var sponsorButtons: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let s = player.askSegment {
                    Button { player.skipSegment(s) } label: {
                        Label("Пропустить: \(Services.category(s.category).name)", systemImage: "forward.fill").font(.caption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                    }
                } else if let h = player.highlight, player.time < h.start - 2, player.time < 30 {
                    Button { player.seek(to: h.start) } label: {
                        Label("К главному моменту", systemImage: "star.fill").font(.caption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                    }
                }
            }
            .padding(.trailing, 12).padding(.bottom, controls ? 64 : 16)
        }
    }
}

struct Shot: Identifiable {
    let image: UIImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}

struct StoryboardFrame: View {
    let board: Storyboard
    let url: String
    let col: Int
    let row: Int
    @State private var sheet: UIImage?
    var body: some View {
        GeometryReader { g in
            if let sheet {
                let cw = sheet.size.width / CGFloat(board.cols), ch = sheet.size.height / CGFloat(board.rows)
                Image(uiImage: sheet)
                    .resizable()
                    .frame(width: g.size.width * CGFloat(board.cols), height: g.size.height * CGFloat(board.rows))
                    .offset(x: -g.size.width * CGFloat(col), y: -g.size.height * CGFloat(row))
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    .clipped()
                    .id("\(cw)\(ch)")
            } else {
                Color.black
            }
        }
        .task(id: url) { sheet = await ImageLoader.shared.image(url) }
    }
}

/// The seek bar: played part, buffered part, chapters, SponsorBlock segments and the most replayed graph.
struct SeekBar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerModel
    @Binding var scrubbing: Double?
    var onEnd: () -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let d = max(player.duration, 1)
            let t = scrubbing ?? player.time
            ZStack(alignment: .leading) {
                if app.store.settings.showHeatmap, let heat = player.watch?.heatmap, !heat.isEmpty {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 14))
                        for h in heat {
                            p.addLine(to: CGPoint(x: w * (h.start + h.duration / 2) / d, y: 14 - 12 * h.intensity))
                        }
                        p.addLine(to: CGPoint(x: w, y: 14))
                    }
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 14)
                    .offset(y: -10)
                }
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                ForEach(player.segments, id: \.uuid) { s in
                    if (app.store.settings.sbActions[s.category] ?? .ignore) != .ignore, s.end > s.start {
                        Rectangle().fill(Color(rgb: Services.category(s.category).color))
                            .frame(width: max(2, w * (s.end - s.start) / d), height: 4)
                            .offset(x: w * s.start / d)
                    }
                }
                Capsule().fill(app.store.accent).frame(width: max(0, min(w, w * t / d)), height: 4)
                if !app.store.settings.hideChapters {
                    ForEach(player.watch?.chapters.dropFirst() ?? [], id: \.start) { c in
                        Rectangle().fill(Color.black).frame(width: 2, height: 4).offset(x: w * c.start / d)
                    }
                }
                Circle().fill(app.store.accent).frame(width: scrubbing == nil ? 12 : 18, height: scrubbing == nil ? 12 : 18)
                    .offset(x: max(0, min(w, w * t / d)) - (scrubbing == nil ? 6 : 9))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in scrubbing = max(0, min(d, Double(v.location.x / w) * d)) }
                    .onEnded { v in
                        player.seek(to: max(0, min(d, Double(v.location.x / w) * d)))
                        scrubbing = nil
                        onEnd()
                    }
            )
        }
        .frame(height: 24)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

/// Quality, speed, captions, audio track, audio only, loop, stats and a screenshot.
struct PlayerSettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerModel
    @Environment(\.dismiss) var dismiss
    @Binding var showStats: Bool
    @Binding var shot: UIImage?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(selection: Binding(get: { player.quality?.label ?? "auto" }, set: { label in
                        player.setQuality(player.variants.first { $0.label == label })
                    })) {
                        Text("Автоматически").tag("auto")
                        ForEach(player.variants, id: \.label) { v in
                            Text(v.label + (v.codecs.contains("av01") ? " AV1" : "")).tag(v.label)
                        }
                    } label: { Label("Качество", systemImage: "slider.horizontal.3") }
                    Picker(selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3], id: \.self) { s in
                            Text(s == 1 ? "Обычная" : String(format: "%gx", s)).tag(s)
                        }
                    } label: { Label("Скорость", systemImage: "speedometer") }
                    if let caps = player.info?.captions, !caps.isEmpty {
                        Picker(selection: Binding(get: { player.caption?.url ?? "" }, set: { url in
                            player.selectCaption(caps.first { $0.url == url })
                        })) {
                            Text("Выключены").tag("")
                            ForEach(caps, id: \.url) { c in Text(c.name + (c.auto ? " (авто)" : "")).tag(c.url) }
                        } label: { Label("Субтитры", systemImage: "captions.bubble") }
                    }
                    if let tracks = player.info?.audioTracks, tracks.count > 1 {
                        Picker(selection: Binding(get: { player.audioTrack ?? "" }, set: { player.setAudioTrack($0) })) {
                            ForEach(tracks, id: \.name) { t in Text(t.name).tag(t.name) }
                        } label: { Label("Звуковая дорожка", systemImage: "waveform") }
                    }
                    Toggle(isOn: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) })) { Label("Только звук", systemImage: "headphones") }
                    Toggle(isOn: $player.loop) { Label("Повтор", systemImage: "repeat") }
                    Toggle(isOn: $app.store.settings.annotations) { Label("Аннотации", systemImage: "text.bubble") }
                    Toggle(isOn: $app.store.settings.ambientGlow) { Label("Подсветка вокруг плеера", systemImage: "sun.max") }
                }
                Section {
                    Button {
                        shot = player.screenshot()
                        if shot == nil { app.show("Кадр недоступен") }
                        dismiss()
                    } label: { Label("Снимок кадра", systemImage: "camera") }
                    Button { dismiss(); showStats = true } label: { Label("Статистика для сисадминов", systemImage: "info.circle") }
                    if let v = player.video {
                        Button {
                            UIPasteboard.general.string = "https://youtu.be/\(v.id)?t=\(Int(player.time))"
                            app.show("Ссылка с текущим временем скопирована")
                        } label: { Label("Копировать ссылку с временем", systemImage: "link") }
                    }
                }
            }
            .navigationTitle("Настройки видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct StatsSheet: View {
    @EnvironmentObject var player: PlayerModel
    @State private var rows: [(String, String)] = []
    var body: some View {
        NavigationStack {
            List(rows.indices, id: \.self) { i in
                HStack(alignment: .top) {
                    Text(rows[i].0).foregroundStyle(.secondary)
                    Spacer()
                    Text(rows[i].1).multilineTextAlignment(.trailing).font(.callout.monospaced())
                }
            }
            .navigationTitle("Статистика")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task {
            while !Task.isCancelled {
                rows = player.stats().rows
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

/// The archived annotations of the video over the picture (16:9 fitted in the player); tap runs their action.
struct AnnotationsLayer: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerModel
    @State private var hovered: String?

    var body: some View {
        GeometryReader { g in
            let rect = fit(g.size)
            let t = player.time
            ZStack(alignment: .topLeading) {
                ForEach(player.annotations.filter { $0.visible(at: t) || ($0.rolloverOf != nil && $0.rolloverOf == hovered) }, id: \.self) { a in
                    box(a, rect)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }

    private func fit(_ s: CGSize) -> CGRect {
        let w = min(s.width, s.height * 16 / 9), h = w * 9 / 16
        return CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder
    private func box(_ a: Annotation, _ r: CGRect) -> some View {
        let w = r.width * a.w / 100, h = r.height * a.h / 100
        let bg = Color(rgb: UInt32(a.bg)).opacity(a.bgAlpha)
        Group {
            if a.kind == .highlight {
                RoundedRectangle(cornerRadius: 2).stroke(Color(rgb: UInt32(a.bg)).opacity(max(a.bgAlpha, 0.5)), lineWidth: 2)
                    .background(Color.white.opacity(0.001))
            } else {
                Text(a.text)
                    .font(.system(size: max(8, r.height * a.textSize / 100)))
                    .foregroundStyle(Color(rgb: UInt32(a.fg)))
                    .multilineTextAlignment(.leading)
                    .padding(3)
                    .frame(width: w, height: h, alignment: .topLeading)
                    .background(bg, in: RoundedRectangle(cornerRadius: a.style == "speech" ? 8 : 2))
            }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onTapGesture { run(a) }
        .offset(x: r.minX + r.width * a.x / 100, y: r.minY + r.height * a.y / 100)
    }

    private func run(_ a: Annotation) {
        if a.kind == .highlight { hovered = hovered == a.id ? nil : a.id }
        switch a.action {
        case .seek(let t): player.seek(to: t)
        case .youtube(let u): app.openLink(u)
        case .web(let u): if let url = URL(string: u) { UIApplication.shared.open(url) }
        case nil: break
        }
    }
}
