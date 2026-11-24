import SwiftUI

struct SubscriptionsView: View {
    @EnvironmentObject var app: AppModel
    @State private var onlyChannel: String?
    @State private var showShorts = false

    var body: some View {
        let subs = app.store.library.subscriptions
        ScrollView {
            if subs.isEmpty {
                EmptyState(icon: "person.2", title: "Подписок пока нет",
                           text: "Подписывайтесь на каналы кнопкой «Подписаться», войдите в аккаунт YouTube или импортируйте подписки из YouTube, NewPipe или FreeTube в Настройках.")
                if app.profile != nil {
                    Button("Взять подписки из аккаунта") { Task { await app.syncSubscriptions() } }.buttonStyle(.borderedProminent)
                }
                NavigationLink(value: Route.settings) { Text("Открыть настройки") }.buttonStyle(.bordered)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(subs) { s in
                            Button { onlyChannel = onlyChannel == s.channel.id ? nil : s.channel.id } label: {
                                VStack(spacing: 6) {
                                    Avatar(url: s.channel.avatar, size: 54, name: s.channel.name)
                                        .overlay(Circle().stroke(onlyChannel == s.channel.id ? app.store.accent : .clear, lineWidth: 3))
                                    Text(s.channel.name).font(.caption2).lineLimit(1).frame(width: 64)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { app.push(.channel(s.channel.id)) } label: { Label("Открыть канал", systemImage: "person.crop.square") }
                                Button(role: .destructive) { app.toggleSubscribe(s.channel) } label: { Label("Отписаться", systemImage: "person.badge.minus") }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
                if let c = onlyChannel {
                    Button { app.push(.channel(c)) } label: { Label("Все видео канала", systemImage: "chevron.right") }
                        .font(.subheadline).padding(.bottom, 4)
                }
                let feed = app.store.settings.filter(app.subsFeed, watched: app.store.settings.hideWatched ? app.watchedIds : [])
                    .filter { onlyChannel == nil || $0.channelId == onlyChannel }
                    .filter { showShorts || !$0.isShort }
                if app.subsFeedLoading && app.subsFeed.isEmpty {
                    ProgressView("Собираем новые видео…").padding(.top, 60)
                } else if feed.isEmpty {
                    EmptyState(icon: "tray", title: "Новых видео нет")
                } else {
                    Feed(items: feed.map(Item.video))
                }
            }
        }
        .refreshable { await app.refreshSubsFeed(force: true) }
        .navigationTitle("Подписки")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Показывать Shorts", isOn: $showShorts)
                    NavigationLink(value: Route.manageSubscriptions) { Label("Управление подписками", systemImage: "list.bullet") }
                    if app.profile != nil {
                        Button { Task { await app.syncSubscriptions() } } label: { Label("Подписки из аккаунта YouTube", systemImage: "person.crop.circle.badge.checkmark") }
                    }
                    Button { Task { await app.refreshSubsFeed(force: true) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await app.refreshSubsFeed() }
    }
}

struct ManageSubscriptionsView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    var body: some View {
        List {
            ForEach(app.store.library.subscriptions.filter { query.isEmpty || $0.channel.name.localizedCaseInsensitiveContains(query) }) { s in
                HStack(spacing: 12) {
                    Avatar(url: s.channel.avatar, size: 40, name: s.channel.name)
                    Text(s.channel.name)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { app.push(.channel(s.channel.id)) }
                .swipeActions { Button(role: .destructive) { app.toggleSubscribe(s.channel) } label: { Label("Отписаться", systemImage: "person.badge.minus") } }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Поиск по подпискам")
        .navigationTitle("Подписки: \(app.store.library.subscriptions.count)")
        .task { await fillAvatars() }
    }

    /// Imported subscriptions come without avatars: fetch the missing ones once.
    private func fillAvatars() async {
        let missing = app.store.library.subscriptions.filter { $0.channel.avatar == nil }.prefix(40)
        for s in missing {
            guard let url = try? await app.innertube.channelAvatar(s.channel.id) else { continue }
            if let i = app.store.library.subscriptions.firstIndex(where: { $0.id == s.id }) {
                app.store.library.subscriptions[i].channel.avatar = url
            }
        }
    }
}
