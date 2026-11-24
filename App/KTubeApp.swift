import AVFoundation
import SwiftUI

@main
struct KTubeApp: App {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.store)
                .environmentObject(app.player)
                .environmentObject(app.downloads)
                .tint(app.store.accent)
                .preferredColorScheme(app.store.settings.theme == .system ? nil : (app.store.settings.theme == .dark ? .dark : .light))
                .onOpenURL { app.open(url: $0) }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .background:
                app.player.didEnterBackground()
                app.store.flush()
            case .active:
                app.player.willEnterForeground()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: PlayerModel
    @State private var newPlaylistName = ""

    var body: some View {
        Group {
            if app.hasKey {
                tabs
            } else {
                KeyView()
            }
        }
        .overlay(alignment: .top) {
            if let t = app.toast {
                Toast(text: t)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { app.toast = nil }
            }
        }
        .animation(.spring(duration: 0.3), value: app.toast)
        .sheet(item: $app.addToPlaylistTarget) { v in
            NewPlaylistSheet(video: v)
        }
        .sheet(item: Binding(get: { app.pendingKeyLink.map { KeyLink(link: $0) } }, set: { app.pendingKeyLink = $0?.link })) { l in
            NavigationStack { KeyView(prefill: l.link, inSheet: true) }
        }
    }

    var tabs: some View {
        TabView(selection: $app.tab) {
            NavigationStack(path: $app.homePath) {
                HomeView().routes()
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .tabItem { Label("Главная", systemImage: "house.fill") }
            .tag(StartTab.home)

            NavigationStack(path: $app.shortsPath) {
                ShortsView().routes()
            }
            .tabItem { Label("Shorts", systemImage: "play.rectangle.on.rectangle.fill") }
            .tag(StartTab.shorts)

            NavigationStack(path: $app.subsPath) {
                SubscriptionsView().routes()
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .tabItem { Label("Подписки", systemImage: "rectangle.stack.badge.play.fill") }
            .tag(StartTab.subscriptions)

            NavigationStack(path: $app.libraryPath) {
                LibraryView().routes()
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .tabItem { Label("Библиотека", systemImage: "books.vertical.fill") }
            .tag(StartTab.library)
        }
        .fullScreenCover(isPresented: $app.showWatch) {
            WatchView()
                .environmentObject(app)
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(app.downloads)
                .tint(store.accent)
                .preferredColorScheme(store.settings.theme == .system ? nil : (store.settings.theme == .dark ? .dark : .light))
        }
        .task { applyDemoScreen() }
    }

    private func applyDemoScreen() {
        #if DEBUG
        switch app.demoScreen {
        case "search": app.homePath.append(Route.search("lofi hip hop"))
        case "watch": app.play(VideoItem(id: "aqz-KE-bpKQ"))
        case "library": app.tab = .library
        case "subscriptions": app.tab = .subscriptions
        case "shorts": app.tab = .shorts
        case "settings": app.tab = .library; app.libraryPath.append(Route.settings)
        case "channel": app.homePath.append(Route.channel("UCSMOQeBJ2RAnuFungnQOxLg"))
        default: break
        }
        #endif
    }
}

struct KeyLink: Identifiable {
    let link: String
    var id: String { link }
}

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { r in
            switch r {
            case .channel(let id): ChannelView(channelId: id)
            case .playlist(let id): PlaylistView(playlistId: id)
            case .localPlaylist(let id): LocalPlaylistView(playlistId: id)
            case .history: HistoryView()
            case .watchLater: VideoListView(kind: .watchLater)
            case .favourites: VideoListView(kind: .favourites)
            case .savedPlaylists: SavedPlaylistsView()
            case .downloads: DownloadsView()
            case .settings: SettingsView()
            case .manageSubscriptions: ManageSubscriptionsView()
            case .search(let q): SearchView(initial: q)
            case .accountPlaylist(let id): PlaylistView(playlistId: id, fromAccount: true)
            case .accountHistory: AccountHistoryView()
            }
        }
    }
}

struct NewPlaylistSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    let video: VideoItem?
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
            }
            .navigationTitle("Новый плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let p = app.store.library.createPlaylist(name)
                        if let video {
                            app.store.library.add(video, toPlaylist: p.id)
                            app.show("Добавлено в «\(p.name)»")
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}
