import SwiftUI
import UIKit

/// Thumbnails and avatars through the gateway (AsyncImage would go straight to i.ytimg.com, which is blocked).
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    var http: HTTPClient?
    private let cache = NSCache<NSString, UIImage>()
    private let inflight = Locked<[String: Task<UIImage?, Never>]>([:])

    init() {
        cache.countLimit = 400
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func image(_ url: String) async -> UIImage? {
        if url.isEmpty { return nil }
        if let c = cached(url) { return c }
        let task: Task<UIImage?, Never> = inflight.with { m in
            if let t = m[url] { return t }
            let t = Task<UIImage?, Never> { [weak self] in
                guard let self, let http = self.http, let r = try? await http.getOK(url), let img = UIImage(data: r.body) else { return nil }
                let prepared = await img.byPreparingForDisplay() ?? img
                self.cache.setObject(prepared, forKey: url as NSString, cost: r.body.count * 4)
                return prepared
            }
            m[url] = t
            return t
        }
        let img = await task.value
        inflight.with { $0[url] = nil }
        return img
    }
}

struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageLoader.shared.cached(url) { image = c; return }
            image = nil
            image = await ImageLoader.shared.image(url)
        }
    }
}

struct Avatar: View {
    let url: String?
    var size: CGFloat = 36
    var name: String = ""
    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.25))
            Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.secondary)
            if url != nil { RemoteImage(url: url).clipShape(Circle()) }
        }
        .frame(width: size, height: size)
    }
}

/// A video thumbnail with its duration, live badge and watch progress.
struct Thumbnail: View {
    @EnvironmentObject var app: AppModel
    let video: VideoItem
    var corner: CGFloat = 12

    var body: some View {
        let entry = app.store.library.entry(video.id)
        let dearrowURL = app.store.settings.dearrowThumbnails ? app.services.cachedBranding(video.id).flatMap { $0 }?.thumbnailTime.map { Services.dearrowThumbnail(video.id, time: $0) } : nil
        RemoteImage(url: dearrowURL ?? video.thumbnail)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if video.isLive {
                    Badge(text: "В ЭФИРЕ", color: .red)
                } else if video.isUpcoming {
                    Badge(text: "СКОРО", color: .black.opacity(0.75))
                } else if let d = video.durationText ?? video.durationSecs.map({ Format.duration($0) }) {
                    Badge(text: d, color: .black.opacity(0.75))
                }
            }
            .overlay(alignment: .bottom) {
                if let e = entry, e.progress > 0.02 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.35))
                            Rectangle().fill(app.store.accent).frame(width: g.size.width * e.progress)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: app.store.settings.roundThumbnails ? corner : 0, style: .continuous))
    }
}

struct Badge: View {
    let text: String
    var color: Color = .black.opacity(0.75)
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }
}

/// The title of a video, DeArrow's when it is on and known.
struct VideoTitle: View {
    @EnvironmentObject var app: AppModel
    let video: VideoItem
    var lines = 2
    @State private var better: String?
    var body: some View {
        Text(better ?? video.title)
            .lineLimit(lines)
            .task(id: video.id) {
                guard app.store.settings.dearrow else { better = nil; return }
                better = await app.services.dearrow(video.id)?.title
            }
    }
}

func metaLine(_ v: VideoItem, settings: AppSettings, channel: Bool = true) -> String {
    var parts: [String] = []
    if channel, !v.channelName.isEmpty { parts.append(v.channelName) }
    if !settings.hideViews, let views = v.viewsText { parts.append(views) }
    if let p = v.publishedText { parts.append(p) }
    return parts.joined(separator: " · ")
}

/// The context menu of a video everywhere in the app.
struct VideoMenu: View {
    @EnvironmentObject var app: AppModel
    let video: VideoItem
    var onRemove: (() -> Void)?
    var removeTitle = "Удалить"

    var body: some View {
        let lib = app.store.library
        Button { app.toggleWatchLater(video) } label: {
            Label(lib.isInWatchLater(video.id) ? "Убрать из «Смотреть позже»" : "Смотреть позже", systemImage: "clock")
        }
        Button { app.toggleFavourite(video) } label: {
            Label(lib.isFavourite(video.id) ? "Убрать из избранного" : "В избранное", systemImage: lib.isFavourite(video.id) ? "star.slash" : "star")
        }
        Menu {
            Button { app.addToPlaylistTarget = video } label: { Label("Новый плейлист…", systemImage: "plus") }
            ForEach(lib.playlists) { p in
                Button(p.name) {
                    app.store.library.add(video, toPlaylist: p.id)
                    app.show("Добавлено в «\(p.name)»")
                }
            }
        } label: { Label("Добавить в плейлист", systemImage: "text.badge.plus") }
        Button { app.player.queue.append(video); app.show("Добавлено в очередь") } label: { Label("В очередь", systemImage: "list.bullet") }
        Button { app.downloads.start(video, quality: nil, audioOnly: false) } label: { Label("Скачать", systemImage: "arrow.down.circle") }
        if let c = video.channelId {
            Button { app.push(.channel(c)) } label: { Label("Перейти на канал", systemImage: "person.crop.square") }
        }
        ShareLink(item: URL(string: video.watchURL)!) { Label("Поделиться", systemImage: "square.and.arrow.up") }
        Button { UIPasteboard.general.string = video.watchURL; app.show("Ссылка скопирована") } label: { Label("Копировать ссылку", systemImage: "link") }
        if let onRemove {
            Button(role: .destructive, action: onRemove) { Label(removeTitle, systemImage: "trash") }
        }
        if video.channelId != nil {
            Button(role: .destructive) { app.blockChannel(id: video.channelId, name: video.channelName) } label: { Label("Не показывать канал", systemImage: "nosign") }
        }
    }
}

/// A big card: thumbnail on top, avatar, title and details under it (feeds).
struct VideoCard: View {
    @EnvironmentObject var app: AppModel
    let video: VideoItem
    var queue: [VideoItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { app.play(video, queue: queue) } label: { Thumbnail(video: video, corner: 14) }
                .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 10) {
                if !app.store.settings.hideAvatars {
                    Button { if let c = video.channelId { app.push(.channel(c)) } } label: {
                        Avatar(url: video.channelAvatar, size: 36, name: video.channelName)
                    }
                    .buttonStyle(.plain)
                }
                Button { app.play(video, queue: queue) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        VideoTitle(video: video).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Text(metaLine(video, settings: app.store.settings)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Menu { VideoMenu(video: video) } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                }
            }
        }
        .contextMenu { VideoMenu(video: video) } preview: { PressPreview(video: video) }
    }
}

/// A compact row: thumbnail on the left (lists, related, search).
struct VideoRow: View {
    @EnvironmentObject var app: AppModel
    let video: VideoItem
    var queue: [VideoItem] = []
    var playlistId: String?
    var onRemove: (() -> Void)?
    var removeTitle = "Удалить"
    var showChannel = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(video: video, corner: 10).frame(width: 160)
            VStack(alignment: .leading, spacing: 4) {
                VideoTitle(video: video, lines: 3).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                Text(metaLine(video, settings: app.store.settings, channel: showChannel)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu { VideoMenu(video: video, onRemove: onRemove, removeTitle: removeTitle) } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 24, height: 28).contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.play(video, queue: queue, playlistId: playlistId) }
        .contextMenu { VideoMenu(video: video, onRemove: onRemove, removeTitle: removeTitle) } preview: { PressPreview(video: video) }
    }
}

struct ChannelRow: View {
    @EnvironmentObject var app: AppModel
    let channel: ChannelItem
    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: channel.avatar, size: 56, name: channel.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).font(.headline).lineLimit(1)
                Text([channel.handle, channel.subscribersText].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            SubscribeButton(channel: channel, compact: true)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.push(.channel(channel.id)) }
    }
}

struct PlaylistRow: View {
    @EnvironmentObject var app: AppModel
    let playlist: PlaylistItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: playlist.thumbnail ?? playlist.firstVideoId.map(Thumbs.video))
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Badge(text: playlist.videoCountText ?? "Плейлист")
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let c = playlist.channelName { Text(c).font(.caption).foregroundStyle(.secondary) }
                Text("Плейлист").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.push(.playlist(playlist.id)) }
    }
}

struct SubscribeButton: View {
    @EnvironmentObject var app: AppModel
    let channel: ChannelItem
    var compact = false
    var body: some View {
        let on = app.store.library.isSubscribed(channel.id)
        Button { app.toggleSubscribe(channel) } label: {
            Text(on ? "Вы подписаны" : "Подписаться")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 6 : 9)
                .foregroundStyle(on ? Color.primary : Color.black)
                .background(on ? AnyShapeStyle(Color.secondary.opacity(0.2)) : AnyShapeStyle(Color.white), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Any item of a feed or search result.
struct ItemView: View {
    let item: Item
    var queue: [VideoItem] = []
    var compact = false
    var body: some View {
        switch item {
        case .video(let v):
            if compact { VideoRow(video: v, queue: queue) } else { VideoCard(video: v, queue: queue) }
        case .channel(let c): ChannelRow(channel: c)
        case .playlist(let p): PlaylistRow(playlist: p)
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var text: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !text.isEmpty { Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorState: View {
    let text: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry { Button("Повторить", action: retry).buttonStyle(.borderedProminent) }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(.black.opacity(0.85), in: Capsule())
            .shadow(radius: 8)
            .padding(.horizontal, 20)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Text with clickable timestamps (seek) and links.
struct RichText: View {
    @EnvironmentObject var app: AppModel
    let text: String
    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "ktube-seek", let t = Double(url.host ?? "") {
                    app.player.seek(to: t)
                    return .handled
                }
                if let host = url.host, host.contains("youtu") {
                    app.openLink(url.absoluteString)
                    return .handled
                }
                return .systemAction
            })
    }

    var attributed: AttributedString {
        var a = AttributedString(text)
        for (range, secs) in Format.timestamps(in: text) {
            if let r = Range(range, in: a) {
                a[r].link = URL(string: "ktube-seek://\(secs)")
                a[r].foregroundColor = app.store.accent
            }
        }
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = text as NSString
            for m in det.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: text), let ar = Range(r, in: a), let url = m.url else { continue }
                a[ar].link = url
                a[ar].foregroundColor = app.store.accent
            }
        }
        return a
    }
}
