import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var downloads: Downloads
    @State private var newPlaylist = false

    var body: some View {
        let lib = app.store.library
        List {
            if !lib.history.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(lib.history.prefix(15)) { e in
                                VStack(alignment: .leading, spacing: 6) {
                                    Thumbnail(video: e.video, corner: 10).frame(width: 170)
                                    VideoTitle(video: e.video).font(.caption.weight(.medium)).frame(width: 170, alignment: .leading)
                                    Text(e.video.channelName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .onTapGesture { app.play(e.video) }
                                .contextMenu { VideoMenu(video: e.video, onRemove: { app.store.library.removeHistory(e.video.id) }, removeTitle: "Удалить из истории") }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowInsets(EdgeInsets())
                } header: {
                    HStack {
                        Text("История")
                        Spacer()
                        NavigationLink(value: Route.history) { Text("Все") }
                    }
                }
            }
            Section {
                NavigationLink(value: Route.history) { row("История", "clock.arrow.circlepath", lib.history.count) }
                NavigationLink(value: Route.watchLater) { row("Смотреть позже", "clock", lib.watchLater.count) }
                NavigationLink(value: Route.favourites) { row("Избранное", "star", lib.favourites.count) }
                NavigationLink(value: Route.savedPlaylists) { row("Сохранённые плейлисты", "bookmark", lib.savedPlaylists.count) }
                NavigationLink(value: Route.downloads) { row("Загрузки", "arrow.down.circle", downloads.entries.count) }
            }
            if app.profile != nil { AccountPlaylistsSection() }
            Section {
                ForEach(lib.playlists) { p in
                    NavigationLink(value: Route.localPlaylist(p.id)) {
                        HStack(spacing: 12) {
                            RemoteImage(url: p.videos.first?.thumbnail).aspectRatio(16 / 9, contentMode: .fit).frame(width: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(p.name)
                                Text("\(p.videos.count) \(Format.plural(p.videos.count, "видео", "видео", "видео"))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { app.store.library.deletePlaylist(lib.playlists[i].id) }
                }
                Button { newPlaylist = true } label: { Label("Новый плейлист", systemImage: "plus") }
            } header: { Text("Плейлисты") }
        }
        .navigationTitle("Библиотека")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.push(.search("")) } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .sheet(isPresented: $newPlaylist) { NewPlaylistSheet(video: nil) }
    }

    private func row(_ title: String, _ icon: String, _ n: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if n > 0 { Text("\(n)").foregroundStyle(.secondary) }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        let entries = app.store.library.history.filter {
            query.isEmpty || $0.video.title.localizedCaseInsensitiveContains(query) || $0.video.channelName.localizedCaseInsensitiveContains(query)
        }
        List {
            if !app.store.settings.historyEnabled {
                Label("История на паузе: новые просмотры не записываются", systemImage: "pause.circle").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(grouped(entries), id: \.0) { (g: (String, [HistoryEntry])) in
                Section(g.0) {
                    ForEach(g.1) { (e: HistoryEntry) in
                        VideoRow(video: e.video, onRemove: { app.store.library.removeHistory(e.video.id) }, removeTitle: "Удалить из истории")
                            .swipeActions { Button(role: .destructive) { app.store.library.removeHistory(e.video.id) } label: { Label("Удалить", systemImage: "trash") } }
                    }
                }
            }
            if entries.isEmpty { EmptyState(icon: "clock", title: "История пуста").listRowSeparator(.hidden) }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Поиск в истории")
        .navigationTitle("История")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { app.store.settings.historyEnabled.toggle() } label: {
                        Label(app.store.settings.historyEnabled ? "Приостановить историю" : "Возобновить историю", systemImage: app.store.settings.historyEnabled ? "pause" : "play")
                    }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Очистить историю", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Очистить всю историю просмотров?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { app.store.library.clearHistory() }
        }
    }

    private func grouped(_ entries: [HistoryEntry]) -> [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        var out: [(String, [HistoryEntry])] = []
        for e in entries {
            let d = Date(timeIntervalSince1970: TimeInterval(e.watchedAt))
            let key = cal.isDateInToday(d) ? "Сегодня" : cal.isDateInYesterday(d) ? "Вчера" : (e.watchedAt == 0 ? "Раньше" : f.string(from: d))
            if out.last?.0 == key { out[out.count - 1].1.append(e) } else { out.append((key, [e])) }
        }
        return out
    }
}

struct VideoListView: View {
    enum Kind { case watchLater, favourites }
    @EnvironmentObject var app: AppModel
    let kind: Kind

    var body: some View {
        let videos = kind == .watchLater ? app.store.library.watchLater : app.store.library.favourites
        List {
            if !videos.isEmpty {
                HStack {
                    Button { if let f = videos.first { app.play(f, queue: videos) } } label: { Label("Воспроизвести", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { let s = videos.shuffled(); if let f = s.first { app.play(f, queue: s) } } label: { Label("Перемешать", systemImage: "shuffle").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(videos) { v in
                VideoRow(video: v, queue: videos, onRemove: { remove(v) }, removeTitle: "Убрать из списка")
                    .swipeActions { Button(role: .destructive) { remove(v) } label: { Label("Убрать", systemImage: "trash") } }
            }
            .onMove { from, to in
                if kind == .watchLater { app.store.library.watchLater.move(fromOffsets: from, toOffset: to) } else { app.store.library.favourites.move(fromOffsets: from, toOffset: to) }
            }
            if videos.isEmpty {
                EmptyState(icon: kind == .watchLater ? "clock" : "star", title: "Список пуст", text: "Добавляйте видео через меню «…» у любого ролика")
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(kind == .watchLater ? "Смотреть позже" : "Избранное")
        .toolbar { EditButton() }
    }

    private func remove(_ v: VideoItem) {
        if kind == .watchLater { app.store.library.watchLater.removeAll { $0.id == v.id } } else { app.store.library.favourites.removeAll { $0.id == v.id } }
    }
}

struct LocalPlaylistView: View {
    @EnvironmentObject var app: AppModel
    let playlistId: String
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let p = app.store.library.playlists.first { $0.id == playlistId }
        let videos = p?.videos ?? []
        List {
            if !videos.isEmpty {
                HStack {
                    Button { if let f = videos.first { app.play(f, queue: videos) } } label: { Label("Воспроизвести", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { let s = videos.shuffled(); if let f = s.first { app.play(f, queue: s) } } label: { Label("Перемешать", systemImage: "shuffle").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(videos) { v in
                VideoRow(video: v, queue: videos, onRemove: { app.store.library.remove(v.id, fromPlaylist: playlistId) }, removeTitle: "Убрать из плейлиста")
            }
            .onDelete { idx in for i in idx { app.store.library.remove(videos[i].id, fromPlaylist: playlistId) } }
            .onMove { from, to in
                if let i = app.store.library.playlists.firstIndex(where: { $0.id == playlistId }) {
                    app.store.library.playlists[i].videos.move(fromOffsets: from, toOffset: to)
                }
            }
            if videos.isEmpty { EmptyState(icon: "music.note.list", title: "Плейлист пуст").listRowSeparator(.hidden) }
        }
        .listStyle(.plain)
        .navigationTitle(p?.name ?? "Плейлист")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { name = p?.name ?? ""; renaming = true } label: { Label("Переименовать", systemImage: "pencil") }
                    EditButton()
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Название плейлиста", isPresented: $renaming) {
            TextField("Название", text: $name)
            Button("Сохранить") { app.store.library.renamePlaylist(playlistId, to: name) }
            Button("Отмена", role: .cancel) {}
        }
    }
}

struct SavedPlaylistsView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        List {
            ForEach(app.store.library.savedPlaylists) { p in PlaylistRow(playlist: p) }
                .onDelete { idx in app.store.library.savedPlaylists.remove(atOffsets: idx) }
            if app.store.library.savedPlaylists.isEmpty {
                EmptyState(icon: "bookmark", title: "Нет сохранённых плейлистов", text: "Нажмите закладку на странице плейлиста YouTube").listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Сохранённые плейлисты")
    }
}

struct DownloadsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var downloads: Downloads

    var body: some View {
        List {
            Text("Видео скачивается через шлюз и смотрится без сети. Пока идёт загрузка, приложение должно оставаться открытым.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(downloads.entries) { e in
                HStack(spacing: 12) {
                    Thumbnail(video: e.video, corner: 8).frame(width: 120)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.video.title).font(.subheadline).lineLimit(2)
                        switch e.state {
                        case .done: Text("Готово · \(e.quality)").font(.caption).foregroundStyle(.secondary)
                        case .failed: Text(e.error ?? "Ошибка").font(.caption).foregroundStyle(.red).lineLimit(2)
                        case .queued: Text("Готовим…").font(.caption).foregroundStyle(.secondary)
                        case .running: ProgressView(value: e.progress).tint(app.store.accent)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if e.state == .done, let u = downloads.localURL(e) {
                        app.player.playOffline(e.video, url: u)
                        app.showWatch = true
                    } else if e.state == .failed {
                        downloads.start(e.video, quality: nil, audioOnly: e.audioOnly)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { downloads.cancel(e.id) } label: { Label("Удалить", systemImage: "trash") }
                }
            }
            if downloads.entries.isEmpty {
                EmptyState(icon: "arrow.down.circle", title: "Загрузок нет", text: "Скачать видео можно в меню «…» или на экране видео").listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Загрузки")
    }
}
