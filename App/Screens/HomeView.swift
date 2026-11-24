import SwiftUI

/// A list of items with pull to refresh and loading more at the end.
struct Feed: View {
    @EnvironmentObject var app: AppModel
    let items: [Item]
    var compact = false
    var loadingMore = false
    var onMore: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 600 : 330), spacing: 16, alignment: .top)], spacing: compact ? 14 : 24) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                ItemView(item: item, queue: [], compact: compact)
                    .onAppear { if i == items.count - 4 { onMore?() } }
                    .id(item.id)
            }
        }
        .padding(.horizontal, 16)
        if loadingMore { ProgressView().padding() }
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var chip = "auto"
    @State private var items: [Item] = []
    @State private var continuation: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var loadedChip = ""

    private var chips: [(String, String)] {
        var out: [(String, String)] = []
        if app.profile != nil { out.append(("account", "Моя главная")) }
        if !app.store.library.history.isEmpty { out.append(("foryou", "Для вас")) } else { out.append(("popular", "Популярное")) }
        if !app.store.library.subscriptions.isEmpty { out.append(("recent", "Новое")) }
        if !app.store.settings.hideExplore {
            for (name, id) in Innertube.explore { out.append((id, name)) }
        }
        return out
    }

    private var current: String { chip == "auto" ? (chips.first?.0 ?? "popular") : chip }

    var body: some View {
        ScrollView {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.0) { c in
                        Button { chip = c.0 } label: {
                            Text(c.1).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundStyle(current == c.0 ? Color(uiColor: .systemBackground) : .primary)
                                .background(current == c.0 ? Color.primary : Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
            if loading && items.isEmpty {
                ProgressView().padding(.top, 80)
            } else if let error, items.isEmpty {
                ErrorState(text: error) { Task { await load(force: true) } }
            } else if items.isEmpty {
                EmptyState(icon: "sparkles.tv", title: "Пока пусто", text: "Найдите что-нибудь через поиск: рекомендации появятся по тому, что вы смотрите.")
            } else {
                Feed(items: items, loadingMore: loadingMore) { Task { await more() } }
            }
        }
        .refreshable { await load(force: true) }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) {
                    AppLogo(size: 26)
                    Text("K-Tube").font(.title3.bold())
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.push(.search("")) } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .task(id: current) { await load(force: false) }
    }

    private func load(force: Bool) async {
        let c = current
        if !force, loadedChip == c, !items.isEmpty { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let (list, cont) = try await fetch(c)
            guard c == current else { return }
            items = app.filtered(list)
            continuation = cont
            loadedChip = c
        } catch {
            if c == current { self.error = error.localizedDescription }
        }
    }

    private func more() async {
        guard let t = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let p = try? await (loadedChip == "account" ? app.account.browseContinue(t) : app.innertube.browseContinue(t)) {
            let seen = Set(items.map(\.id))
            items += app.filtered(p.items).filter { !seen.contains($0.id) }
            continuation = p.continuation
        }
    }

    private func fetch(_ c: String) async throws -> ([Item], String?) {
        let it = app.innertube
        switch c {
        case "account":
            let p = try await app.account.home()
            return (p.items, p.continuation)
        case "foryou":
            let lib = app.store.library
            let seeds = Recommend.seeds(lib.history)
            let queries = Array(lib.searchHistory.prefix(3))
            if app.subsFeed.isEmpty, !lib.subscriptions.isEmpty { await app.refreshSubsFeed() }
            let subsNew = Array(app.subsFeed.prefix(20))
            var lists: [[VideoItem]] = await withTaskGroup(of: [VideoItem].self) { g in
                for id in seeds { g.addTask { (try? await it.watchNext(id).related.compactMap(\.video)) ?? [] } }
                for q in queries { g.addTask { Array(((try? await it.search(q).videos) ?? []).prefix(8)) } }
                var out: [[VideoItem]] = []
                for await r in g { out.append(r) }
                return out
            }
            if !subsNew.isEmpty { lists.insert(subsNew, at: 0) }
            let watched = Set(lib.history.map(\.video.id))
            let mixed = Recommend.interleave(lists, exclude: watched).filter { !$0.isShort }
            if mixed.isEmpty { return try await fetch("popular") }
            return (mixed.map(Item.video), nil)
        case "popular":
            let lists: [[VideoItem]] = await withTaskGroup(of: [VideoItem].self) { g in
                for (_, id) in Innertube.explore.prefix(4) { g.addTask { (try? await it.explorePage(id).videos) ?? [] } }
                var out: [[VideoItem]] = []
                for await r in g { out.append(r) }
                return out
            }
            let mixed = Recommend.interleave(lists, exclude: [], step: 1)
            if mixed.isEmpty { throw KTubeError("Не удалось загрузить ленту. Проверьте ключ и связь со шлюзом") }
            return (mixed.map(Item.video), nil)
        case "recent":
            await app.refreshSubsFeed()
            let cutoff = Format.now() - 14 * 86400
            return (app.subsFeed.filter { ($0.publishedTs ?? 0) >= cutoff }.map(Item.video), nil)
        default:
            let p = try await it.explorePage(c)
            return (p.items, p.continuation)
        }
    }
}
