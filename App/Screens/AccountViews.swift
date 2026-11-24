import SwiftUI
import UIKit

/// Sign-in to the YouTube account with a code at google.com/device (the TV method: no password goes through the app).
struct SignInSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL
    @State private var code: Account.DeviceCode?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 52)).foregroundStyle(.tint)
                Text("Вход в аккаунт YouTube").font(.title2.bold())
                Text("Откройте google.com/device в браузере на этом или другом устройстве и введите код. Пароль вводится только на странице Google.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let code {
                    Text(code.userCode).font(.system(size: 36, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button {
                            UIPasteboard.general.string = code.userCode
                            app.show("Код скопирован")
                        } label: { Label("Копировать", systemImage: "doc.on.doc") }
                            .buttonStyle(.bordered)
                        Button {
                            UIPasteboard.general.string = code.userCode
                            if let u = URL(string: code.verificationURL) { openURL(u) }
                        } label: { Label("Открыть страницу", systemImage: "safari") }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Ждём подтверждения…").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if error == nil {
                    ProgressView()
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center) }
                Text("Вход даёт вашу главную YouTube, подписки, плейлисты, лайки, историю и сообщения в чат трансляций. Без входа всё остальное работает так же.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        .task { await run() }
    }

    private func run() async {
        do {
            let dc = try await app.account.startLogin()
            code = dc
            var interval = UInt64(max(dc.interval, 3))
            let deadline = Date().addingTimeInterval(TimeInterval(dc.expiresIn))
            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                switch try await app.account.poll(dc) {
                case .pending: continue
                case .slowDown: interval += 2
                case .done(let p):
                    app.accountChanged()
                    app.show("Вы вошли как \(p.name)")
                    dismiss()
                    return
                }
            }
            if !Task.isCancelled { error = "Код устарел, откройте вход заново" }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AccountSection: View {
    @EnvironmentObject var app: AppModel
    @State private var signingIn = false
    @State private var syncing = false

    var body: some View {
        Section {
            if let p = app.profile {
                HStack(spacing: 12) {
                    Avatar(url: p.avatar, size: 40, name: p.name)
                    VStack(alignment: .leading) {
                        Text(p.name)
                        if let h = p.handle { Text(h).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button { run { await app.syncSubscriptions() } } label: { Label("Взять подписки из аккаунта", systemImage: "person.2") }
                Button { run { await app.syncHistory() } } label: { Label("Взять историю просмотров и поиска", systemImage: "clock.arrow.circlepath") }
                Button("Выйти из аккаунта", role: .destructive) { app.signOut() }
            } else {
                Button { signingIn = true } label: { Label("Войти в аккаунт YouTube", systemImage: "person.crop.circle") }
            }
        } header: {
            HStack {
                Text("Аккаунт YouTube")
                if syncing { ProgressView().scaleEffect(0.7) }
            }
        } footer: {
            Text("Необязательно. Подписка и лайк с этого iPhone уходят и в аккаунт. Запросы идут через тот же шлюз.")
        }
        .sheet(isPresented: $signingIn) { SignInSheet() }
    }

    private func run(_ f: @escaping () async -> Void) {
        syncing = true
        Task {
            await f()
            syncing = false
        }
    }
}

/// The account's playlists in the library.
struct AccountPlaylistsSection: View {
    @EnvironmentObject var app: AppModel
    @State private var playlists: [PlaylistItem] = []
    @State private var loaded = false

    var body: some View {
        Section {
            NavigationLink(value: Route.accountHistory) { Label("История аккаунта", systemImage: "clock.badge.checkmark") }
            ForEach(playlists) { p in
                NavigationLink(value: Route.accountPlaylist(p.id)) {
                    HStack(spacing: 12) {
                        RemoteImage(url: p.thumbnail).aspectRatio(16 / 9, contentMode: .fit).frame(width: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(p.title)
                            if let c = p.videoCountText { Text(c).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if !loaded { ProgressView().frame(maxWidth: .infinity) }
        } header: { Text("Аккаунт YouTube") }
        .task {
            playlists = (try? await app.account.playlists()) ?? []
            loaded = true
        }
    }
}

struct AccountHistoryView: View {
    @EnvironmentObject var app: AppModel
    @State private var videos: [VideoItem] = []
    @State private var continuation: String?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            ForEach(Array(videos.enumerated()), id: \.element.id) { i, v in
                VideoRow(video: v, onRemove: { remove(v) }, removeTitle: "Удалить из истории YouTube")
                    .onAppear { if i == videos.count - 4 { Task { await more() } } }
                    .swipeActions { Button(role: .destructive) { remove(v) } label: { Label("Удалить", systemImage: "trash") } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error, videos.isEmpty { Text(error).foregroundStyle(.secondary) }
        }
        .listStyle(.plain)
        .navigationTitle("История аккаунта")
        .refreshable { await load() }
        .task { if videos.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let p = try await app.account.history()
            videos = p.items.compactMap(\.video)
            continuation = p.continuation
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func more() async {
        guard let t = continuation, !loading else { return }
        loading = true
        defer { loading = false }
        if let p = try? await app.account.browseContinue(t) {
            let seen = Set(videos.map(\.id))
            videos += p.items.compactMap(\.video).filter { !seen.contains($0.id) }
            continuation = p.continuation
        }
    }

    private func remove(_ v: VideoItem) {
        Task {
            do {
                try await app.account.removeFromHistory(v.id)
                videos.removeAll { $0.id == v.id }
            } catch {
                app.show(error)
            }
        }
    }
}
