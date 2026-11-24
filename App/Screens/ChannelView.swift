import SwiftUI

struct ChannelView: View {
    @EnvironmentObject var app: AppModel
    let channelId: String
    @State private var page: ChannelPage?
    @State private var tab: String?
    @State private var items: [Item] = []
    @State private var continuation: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var searching = false
    @State private var query = ""
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            if let page {
                header(page)
                tabs(page)
                if loading && items.isEmpty {
                    ProgressView().padding(.top, 40)
                } else if items.isEmpty {
                    EmptyState(icon: "rectangle.stack", title: "Здесь пока ничего нет")
                } else {
                    Feed(items: items, compact: true, loadingMore: loadingMore) { Task { await more() } }
                        .padding(.top, 8)
                }
            } else if let error {
                ErrorState(text: error) { Task { await load() } }
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .navigationTitle(page?.info.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { searching.toggle() } label: { Label("Поиск по каналу", systemImage: "magnifyingglass") }
                    Button { showAbout = true } label: { Label("О канале", systemImage: "info.circle") }
                    ShareLink(item: URL(string: "https://www.youtube.com/channel/\(channelId)")!) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { app.blockChannel(id: channelId, name: page?.info.name ?? channelId) } label: { Label("Не показывать канал", systemImage: "nosign") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .searchable(text: $query, isPresented: $searching, prompt: "Поиск по каналу")
        .onSubmit(of: .search) { Task { await channelSearch() } }
        .sheet(isPresented: $showAbout) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let p = page {
                            Text(p.info.name).font(.title2.bold())
                            Text([p.info.handle, p.info.subscribersText, p.info.videoCountText].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            RichText(text: p.info.description ?? "")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("О канале")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .task { if page == nil { await load() } }
    }

    private func header(_ p: ChannelPage) -> some View {
        VStack(spacing: 12) {
            if let b = p.banner {
                RemoteImage(url: b).aspectRatio(6.2, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
            }
            HStack(spacing: 14) {
                Avatar(url: p.info.avatar, size: 72, name: p.info.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.info.name).font(.title3.bold()).lineLimit(2)
                    Text([p.info.handle, p.info.subscribersText, p.info.videoCountText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            if let d = p.info.description, !d.isEmpty {
                Button { showAbout = true } label: {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
            HStack {
                SubscribeButton(channel: p.info)
                Spacer()
                if let first = items.compactMap(\.video).first {
                    Button { app.play(first, queue: items.compactMap(\.video)) } label: { Label("Смотреть", systemImage: "play.fill") }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
    }

    private func tabs(_ p: ChannelPage) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(p.tabs.filter { $0.params != nil || $0.selected }, id: \.title) { t in
                    let on = (tab ?? p.tabs.first(where: \.selected)?.title) == t.title
                    Button {
                        tab = t.title
                        Task { await loadTab(t) }
                    } label: {
                        VStack(spacing: 6) {
                            Text(t.title).font(.subheadline.weight(on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary)
                            Capsule().fill(on ? Color.primary : .clear).frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let p = try await app.innertube.channel(channelId)
            page = p
            // the home tab is a mix of shelves: open "Videos" right away when there is one
            if let v = p.tabs.first(where: { ["videos", "видео"].contains($0.title.lowercased()) }) {
                tab = v.title
                await loadTab(v)
            } else {
                items = app.filtered(p.page.items)
                continuation = p.page.continuation
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadTab(_ t: ChannelTab) async {
        loading = true
        items = []
        defer { loading = false }
        if let p = try? await app.innertube.channel(channelId, tabParams: t.params) {
            items = app.filtered(p.page.items)
            continuation = p.page.continuation
        }
    }

    private func more() async {
        guard let t = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let p = try? await app.innertube.browseContinue(t) {
            var add = p.items
            let info = page?.info
            for i in add.indices {
                if case .video(var v) = add[i] {
                    if v.channelName.isEmpty { v.channelName = info?.name ?? "" }
                    if v.channelId == nil { v.channelId = info?.id }
                    add[i] = .video(v)
                }
            }
            let seen = Set(items.map(\.id))
            items += app.filtered(add).filter { !seen.contains($0.id) }
            continuation = p.continuation
        }
    }

    private func channelSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        items = []
        defer { loading = false }
        if let p = try? await app.innertube.channelSearch(channelId, query: q) {
            items = app.filtered(p.items)
            continuation = nil
            tab = nil
        }
    }
}

struct PlaylistView: View {
    @EnvironmentObject var app: AppModel
    let playlistId: String
    var fromAccount = false
    @State private var page: PlaylistPage?
    @State private var videos: [VideoItem] = []
    @State private var continuation: String?
    @State private var error: String?
    @State private var loadingMore = false

    var body: some View {
        List {
            if let p = page {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        RemoteImage(url: p.info.thumbnail).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text(p.info.title).font(.title3.bold())
                        Text([p.info.channelName, p.info.videoCountText].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if let d = p.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        HStack {
                            Button { if let f = videos.first { app.play(f, queue: videos, playlistId: playlistId) } } label: {
                                Label("Воспроизвести", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                let s = videos.shuffled()
                                if let f = s.first { app.play(f, queue: s) }
                            } label: { Label("Перемешать", systemImage: "shuffle").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(Array(videos.enumerated()), id: \.element.id) { i, v in
                        VideoRow(video: v, queue: videos, playlistId: playlistId)
                            .onAppear { if i == videos.count - 4 { Task { await more() } } }
                    }
                    if loadingMore { ProgressView() }
                }
            } else if let error {
                ErrorState(text: error) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(page?.info.title ?? "Плейлист")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let p = page {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.store.library.toggleSaved(p.info)
                        app.show(app.store.library.isSaved(p.info.id) ? "Плейлист сохранён в библиотеку" : "Плейлист убран из библиотеки")
                    } label: { Image(systemName: app.store.library.isSaved(p.info.id) ? "bookmark.fill" : "bookmark") }
                }
            }
        }
        .task { if page == nil { await load() } }
    }

    private func load() async {
        do {
            let p = fromAccount ? try await app.account.playlist(playlistId) : try await app.innertube.playlist(playlistId)
            page = p
            videos = p.videos
            continuation = p.continuation
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func more() async {
        guard let t = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let p = try? await (fromAccount ? app.account.browseContinue(t) : app.innertube.browseContinue(t)) {
            let seen = Set(videos.map(\.id))
            videos += p.videos.filter { !seen.contains($0.id) }
            continuation = p.continuation
        }
    }
}
