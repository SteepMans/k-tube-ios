import SwiftUI
import UIKit

struct WatchView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var downloads: Downloads
    @Environment(\.verticalSizeClass) var vsize
    @State private var showDescription = false
    @State private var showComments = false
    @State private var showChapters = false
    @State private var showChat = false
    @State private var showQueue = false
    @State private var dragY: CGFloat = 0
    @State private var rating: String?

    var landscape: Bool { vsize == .compact }

    var body: some View {
        Group {
            if landscape {
                PlayerArea(fullscreen: true) { rotate(portrait: true) }
                    .ignoresSafeArea()
                    .statusBarHidden()
            } else {
                VStack(spacing: 0) {
                    PlayerArea(fullscreen: false) { rotate(portrait: false) }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background {
                            // ambient glow: the picture's colours spill around the player
                            if app.store.settings.ambientGlow, !player.audioOnly, let v = player.video {
                                RemoteImage(url: v.thumbnail).blur(radius: 50).opacity(0.55).scaleEffect(1.35).allowsHitTesting(false)
                            }
                        }
                        .zIndex(1)
                        .gesture(DragGesture().onChanged { v in dragY = max(0, v.translation.height) }.onEnded { v in
                            if v.translation.height > 120 { app.showWatch = false }
                            dragY = 0
                        })
                    details
                }
                .offset(y: dragY)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .sheet(isPresented: $showDescription) { DescriptionSheet() }
        .sheet(isPresented: $showComments) {
            if let t = player.watch?.commentsToken { CommentsSheet(token: t, sort: player.watch?.commentsSort ?? (nil, nil)) }
        }
        .sheet(isPresented: $showChapters) { ChaptersSheet() }
        .sheet(isPresented: $showChat) {
            if let c = player.watch?.liveChat {
                LiveChatSheet(tokens: c, channelId: player.watch?.channel.id ?? player.video?.channelId ?? "", videoId: player.video?.id ?? "")
            }
        }
        .onChange(of: player.video?.id) { _, _ in rating = nil }
        .sheet(isPresented: $showQueue) { QueueSheet() }
    }

    private func rotate(portrait: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: portrait ? .portrait : .landscapeRight)) { _ in }
    }

    private var details: some View {
        ScrollView {
            if let v = player.video {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(player.branding?.title ?? (v.title.isEmpty ? (player.watch?.title ?? "") : v.title))
                            .font(.title3.bold())
                        HStack(spacing: 6) {
                            if !app.store.settings.hideViews, let views = player.watch?.viewsText ?? v.viewsText { Text(views) }
                            if let d = player.watch?.dateText, !d.isEmpty { Text("· \(d)") }
                            if !app.store.settings.hideDescription {
                                Button("ещё") { showDescription = true }.font(.caption.bold())
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    channelRow(v)
                    actions(v)
                    if let c = player.currentChapter, !app.store.settings.hideChapters, (player.watch?.chapters.count ?? 0) > 1 {
                        Button { showChapters = true } label: {
                            HStack {
                                Image(systemName: "list.bullet.rectangle")
                                Text(c.title).lineLimit(1)
                                Spacer()
                                Text("Главы: \(player.watch?.chapters.count ?? 0)").foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(12)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    if player.watch?.liveChat != nil {
                        Button { showChat = true } label: { panel(icon: "bubble.left.and.bubble.right", title: "Чат трансляции", subtitle: "Открыть") }
                            .buttonStyle(.plain)
                    }
                    if !player.queue.isEmpty {
                        Button { showQueue = true } label: {
                            panel(icon: "list.number", title: player.playlistTitle ?? "Очередь",
                                  subtitle: queuePosition)
                        }
                        .buttonStyle(.plain)
                    }
                    if !app.store.settings.hideComments, player.watch?.commentsToken != nil {
                        Button { showComments = true } label: {
                            panel(icon: "text.bubble", title: "Комментарии", subtitle: player.watch?.commentCountText ?? "Открыть")
                        }
                        .buttonStyle(.plain)
                    }
                    if !app.store.settings.hideRelated {
                        let related = app.filtered(player.watch?.related ?? [])
                        if !related.isEmpty {
                            Text(app.store.settings.autoplay ? "Далее" : "Похожие").font(.headline).padding(.top, 4)
                            LazyVStack(spacing: 14) {
                                ForEach(related) { item in ItemView(item: item, compact: true) }
                            }
                        } else if player.watch == nil {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var queuePosition: String {
        guard let v = player.video, let i = player.queue.firstIndex(where: { $0.id == v.id }) else { return "\(player.queue.count) видео" }
        return "\(i + 1) из \(player.queue.count)"
    }

    private func panel(icon: String, title: String, subtitle: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title).bold()
            Spacer()
            Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(12)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func channelRow(_ v: VideoItem) -> some View {
        let ch = player.watch?.channel
        let channel = ChannelItem(id: ch?.id.isEmpty == false ? ch!.id : (v.channelId ?? ""), name: ch?.name.isEmpty == false ? ch!.name : v.channelName, avatar: ch?.avatar ?? v.channelAvatar)
        return HStack(spacing: 10) {
            Button { if !channel.id.isEmpty { app.push(.channel(channel.id)) } } label: {
                HStack(spacing: 10) {
                    Avatar(url: channel.avatar, size: 38, name: channel.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name).font(.subheadline.bold()).lineLimit(1)
                        if let s = ch?.subscribersText { Text(s).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if !channel.id.isEmpty { SubscribeButton(channel: channel) }
        }
    }

    private func actions(_ v: VideoItem) -> some View {
        let lib = app.store.library
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let likes = player.votes.map { Format.compact($0.likes) } ?? player.watch?.likesText ?? ""
                chip(rating == "like" ? "hand.thumbsup.fill" : "hand.thumbsup", likes) { rate(v, "like") }
                chip(rating == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown", player.votes.map { Format.compact($0.dislikes) } ?? "") { rate(v, "dislike") }
                chip(lib.isInWatchLater(v.id) ? "clock.fill" : "clock", "Позже") { app.toggleWatchLater(v) }
                chip(lib.isFavourite(v.id) ? "star.fill" : "star", "Избранное") { app.toggleFavourite(v) }
                Menu {
                    Button { app.addToPlaylistTarget = v } label: { Label("Новый плейлист…", systemImage: "plus") }
                    ForEach(lib.playlists) { p in
                        Button(p.name) { app.store.library.add(v, toPlaylist: p.id); app.show("Добавлено в «\(p.name)»") }
                    }
                } label: { chipLabel("text.badge.plus", "В плейлист") }
                Menu {
                    Button("Лучшее (до 1080p)") { downloads.start(v, quality: nil, audioOnly: false) }
                    ForEach(player.variants.filter { $0.qualityClass <= 1080 && !$0.codecs.contains("av01") }, id: \.label) { q in
                        Button(q.label) { downloads.start(v, quality: q, audioOnly: false) }
                    }
                    Button("Только звук") { downloads.start(v, quality: nil, audioOnly: true) }
                } label: { chipLabel(downloads.entry(v.id)?.state == .done ? "checkmark.circle" : "arrow.down.circle", "Скачать") }
                ShareLink(item: URL(string: v.watchURL)!) { chipLabel("square.and.arrow.up", "Поделиться") }
                chip(player.loop ? "repeat.1" : "repeat", "Повтор") { player.loop.toggle() }
            }
        }
    }

    /// Like or dislike on the YouTube account; without signing in it is not possible (YouTube needs an account).
    private func rate(_ v: VideoItem, _ kind: String) {
        guard app.profile != nil else {
            app.show("Лайки ставятся в аккаунт YouTube: войдите в Настройках")
            return
        }
        let undo = rating == kind
        Task {
            do {
                try await app.account.like(v.id, undo ? "removelike" : kind)
                rating = undo ? nil : kind
            } catch {
                app.show(error)
            }
        }
    }

    private func chip(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(icon, text) }.buttonStyle(.plain)
    }

    private func chipLabel(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.primary)
    }
}

struct DescriptionSheet: View {
    @EnvironmentObject var player: PlayerModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(player.watch?.title ?? player.video?.title ?? "").font(.title3.bold())
                    HStack(spacing: 18) {
                        if let v = player.watch?.viewsText { stat(v, "просмотры") }
                        if let d = player.watch?.dateText { stat(d, "дата") }
                        if let l = player.votes { stat(Format.compact(l.likes), "лайки") }
                    }
                    RichText(text: player.watch?.description ?? player.info?.description ?? "")
                        .font(.subheadline)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Описание")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading) {
            Text(v).font(.subheadline.bold())
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ChaptersSheet: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.watch?.chapters ?? [], id: \.start) { c in
                    HStack(spacing: 12) {
                        if let t = c.thumbnail { RemoteImage(url: t).aspectRatio(16 / 9, contentMode: .fit).frame(width: 96).clipShape(RoundedRectangle(cornerRadius: 6)) }
                        VStack(alignment: .leading) {
                            Text(c.title).font(.subheadline.weight(player.currentChapter == c ? .bold : .regular))
                            Text(Format.duration(c.start)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .id(c.start)
                    .contentShape(Rectangle())
                    .onTapGesture { player.seek(to: c.start); dismiss() }
                }
                .onAppear { if let c = player.currentChapter { proxy.scrollTo(c.start, anchor: .center) } }
            }
            .navigationTitle("Главы")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

struct QueueSheet: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(player.queue) { v in
                    HStack(spacing: 10) {
                        if v.id == player.video?.id { Image(systemName: "play.fill").foregroundStyle(.tint) }
                        Thumbnail(video: v, corner: 6).frame(width: 100)
                        VStack(alignment: .leading) {
                            Text(v.title).font(.subheadline).lineLimit(2)
                            Text(v.channelName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.load(v); dismiss() }
                }
                .onDelete { player.queue.remove(atOffsets: $0) }
                .onMove { player.queue.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .navigationTitle(player.playlistTitle ?? "Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button { player.queue.shuffle() } label: { Image(systemName: "shuffle") } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct CommentsSheet: View {
    @EnvironmentObject var app: AppModel
    let token: String
    let sort: (String?, String?)
    @State private var page = CommentPage()
    @State private var comments: [Comment] = []
    @State private var loading = false
    @State private var newest = false
    @State private var timed = false
    @State private var replies: [String: [Comment]] = [:]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if timed {
                    let shown = timedComments
                    if shown.isEmpty {
                        Text("Комментарии с отметками времени появятся, когда видео дойдёт до них").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { c in CommentRow(comment: c) }
                }
                ForEach(timed ? [] : comments) { c in
                    CommentRow(comment: c)
                    if let r = replies[c.id] {
                        ForEach(r) { reply in CommentRow(comment: reply).padding(.leading, 36) }
                    } else if let t = c.repliesToken {
                        Button("Ответы: \(c.replyCount)") { Task { await loadReplies(c.id, t) } }
                            .font(.caption.bold()).padding(.leading, 44)
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else if page.continuation != nil {
                    Color.clear.frame(height: 1).onAppear { Task { await more() } }
                }
                if let error, comments.isEmpty { Text(error).foregroundStyle(.secondary) }
            }
            .listStyle(.plain)
            .navigationTitle("Комментарии" + (page.countText.map { " · \($0)" } ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Сортировка", selection: Binding(get: { timed ? 2 : (newest ? 1 : 0) }, set: { v in
                            timed = v == 2
                            if v != 2 { newest = v == 1 }
                        })) {
                            Text("Популярные").tag(0)
                            Text("Новые").tag(1)
                            Text("По времени видео").tag(2)
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: newest) { await load() }
        .task(id: timed) { if timed { await loadForTimed() } }
    }

    @EnvironmentObject var player: PlayerModel

    /// Like youtube.com's "Timed": comments that mention a moment appear once playback reaches it, latest first.
    private var timedComments: [Comment] {
        let t = Int(player.time)
        return comments.compactMap { c -> (Comment, Int)? in
            guard let s = Format.timestamps(in: c.text).map(\.seconds).filter({ $0 <= t }).max() else { return nil }
            return (c, s)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// The timed view looks through more comments than one page.
    private func loadForTimed() async {
        var pages = 0
        while timed, pages < 6, page.continuation != nil {
            await more()
            pages += 1
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        comments = []
        replies = [:]
        let t = newest ? (page.sortNewToken ?? sort.1 ?? token) : (page.sortTopToken ?? sort.0 ?? token)
        do {
            let p = try await app.innertube.comments(t)
            let keepSort = (page.sortTopToken, page.sortNewToken)
            page = p
            if page.sortTopToken == nil { page.sortTopToken = keepSort.0 }
            if page.sortNewToken == nil { page.sortNewToken = keepSort.1 }
            comments = p.comments
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func more() async {
        guard let t = page.continuation, !loading else { return }
        loading = true
        defer { loading = false }
        if let p = try? await app.innertube.comments(t) {
            let seen = Set(comments.map(\.id))
            comments += p.comments.filter { !seen.contains($0.id) }
            page.continuation = p.continuation
        }
    }

    private func loadReplies(_ id: String, _ token: String) async {
        if let p = try? await app.innertube.comments(token) { replies[id] = p.comments }
    }
}

struct CommentRow: View {
    @EnvironmentObject var app: AppModel
    let comment: Comment
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: comment.authorAvatar, size: 32, name: comment.author.replacingOccurrences(of: "@", with: ""))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if comment.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(comment.author).font(.caption.bold())
                        .padding(.horizontal, comment.isCreator ? 6 : 0)
                        .background(comment.isCreator ? Color.secondary.opacity(0.25) : .clear, in: Capsule())
                    if comment.isVerified { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(comment.published).font(.caption).foregroundStyle(.secondary)
                }
                RichText(text: comment.text).font(.subheadline).lineLimit(expanded ? nil : 6)
                    .onTapGesture { expanded.toggle() }
                HStack(spacing: 14) {
                    if !comment.likes.isEmpty { Label(comment.likes, systemImage: "hand.thumbsup").font(.caption) }
                    if comment.hearted { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.red) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Live chat of a stream; writing needs the YouTube account.
struct LiveChatSheet: View {
    @EnvironmentObject var app: AppModel
    let tokens: (String, String)
    var channelId = ""
    var videoId = ""
    @State private var messages: [ChatMessage] = []
    @State private var all = false
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(messages) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(m.author).font(.caption.bold()).foregroundStyle(m.isOwner ? Color.yellow : m.isModerator ? Color.blue : Color.secondary)
                            if let s = m.superChat { Text(s).font(.caption.bold()).padding(.horizontal, 4).background(Color.orange, in: Capsule()) }
                        }
                        Text(m.text).font(.subheadline)
                    }
                    .id(m.id)
                }
                .listStyle(.plain)
                .onChange(of: messages.count) { _, _ in if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) {
                if app.profile != nil, !channelId.isEmpty {
                    HStack {
                        TextField("Сообщение", text: $draft).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit(send)
                        Button(action: send) { Image(systemName: "paperplane.fill") }
                            .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(10)
                    .background(.bar)
                }
            }
            .navigationTitle("Чат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("", selection: $all) {
                        Text("Топ").tag(false)
                        Text("Все").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: all) { await poll() }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            do {
                try await app.account.sendChat(channelId: channelId, videoId: videoId, message: text)
                draft = ""
            } catch {
                app.show(error)
            }
            sending = false
        }
    }

    private func poll() async {
        messages = []
        var token: String? = all ? tokens.1 : tokens.0
        while let t = token, !Task.isCancelled {
            guard let b = try? await app.innertube.liveChat(t) else { return }
            messages += b.messages
            if messages.count > 300 { messages.removeFirst(messages.count - 300) }
            token = b.continuation
            try? await Task.sleep(nanoseconds: UInt64(max(1000, min(b.timeoutMs, 10000))) * 1_000_000)
        }
    }
}

/// The bar above the tab bar while a video plays and the watch screen is closed.
struct MiniPlayer: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        if let v = player.video, !app.showWatch {
            VStack(spacing: 0) {
                GeometryReader { g in
                    Rectangle().fill(app.store.accent).frame(width: player.duration > 0 ? g.size.width * min(1, player.time / player.duration) : 0)
                }
                .frame(height: 2)
                HStack(spacing: 12) {
                    ZStack {
                        if player.audioOnly || player.pipActive { RemoteImage(url: v.thumbnail) } else { MainPlayerLayer(layer: player.layer) }
                    }
                    .frame(width: 110, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(v.channelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                    Button { player.stop() } label: { Image(systemName: "xmark").font(.title3) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { app.showWatch = true }
            }
            .foregroundStyle(.primary)
            .background(.regularMaterial)
        }
    }
}
