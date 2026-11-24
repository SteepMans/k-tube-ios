import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var info: Gateway.Info?
    @State private var infoError: String?
    @State private var checking = false
    @State private var confirmForget = false
    @State private var importing = false
    @State private var importResult: String?
    @State private var exportFile: ExportFile?
    @State private var newKeyword = ""
    @State private var sbUser: SBUserInfo?
    @State private var stats = GatewayService.Stats()

    private var s: Binding<AppSettings> { $app.settings }

    var body: some View {
        Form {
            gatewaySection
            AccountSection()
            Section("Внешний вид") {
                Picker("Тема", selection: s.theme) { ForEach(Theme.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Акцентный цвет", selection: s.accent) {
                    ForEach(AppSettings.accents.map { Pair(id: $0.0, title: $0.1) }) { (a: Pair) in
                        HStack { Circle().fill(Color(hex: a.id)).frame(width: 14, height: 14); Text(a.title) }.tag(a.id)
                    }
                }
                Toggle("Скруглённые обложки", isOn: s.roundThumbnails)
                Picker("Стартовая вкладка", selection: s.startTab) { ForEach(StartTab.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Язык YouTube", selection: s.hl) { PairOptions(items: AppSettings.languages) }
                Picker("Регион", selection: s.gl) { PairOptions(items: AppSettings.regions) }
            }
            Section("Воспроизведение") {
                Picker("Качество по умолчанию", selection: s.defaultQuality) {
                    ForEach(AppSettings.qualities, id: \.self) { Text(AppSettings.qualityTitle($0)).tag($0) }
                }
                Picker("Качество в мобильной сети", selection: s.cellularQuality) {
                    ForEach(AppSettings.qualities, id: \.self) { Text(AppSettings.qualityTitle($0)).tag($0) }
                }
                Toggle("Запоминать выбранное качество", isOn: s.rememberQuality)
                Picker("Скорость", selection: s.speed) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text($0 == 1 ? "Обычная" : String(format: "%gx", $0)).tag($0) }
                }
                Toggle("Скорость для каждого канала", isOn: s.speedPerChannel)
                Toggle("Автовоспроизведение следующего", isOn: s.autoplay)
                Toggle("Продолжать с места остановки", isOn: s.resume)
                Toggle("Звук в фоне и на заблокированном экране", isOn: s.backgroundPlay)
                Toggle("Картинка в картинке при сворачивании", isOn: s.autoPiP)
                Toggle("Только звук по умолчанию", isOn: s.audioOnly)
                Toggle("Оригинальная звуковая дорожка", isOn: s.originalAudio)
                Toggle("Удержание — скорость 2x", isOn: s.holdFor2x)
                Stepper("Перемотка двойным касанием: \(app.store.settings.seekStep) с", value: s.seekStep, in: 5...60, step: 5)
                Toggle("AV1, если iPhone декодирует его аппаратно", isOn: s.allowAV1)
                Toggle("График популярных моментов", isOn: s.showHeatmap)
                Toggle("Кадры при перемотке", isOn: s.seekPreview)
                Toggle("Подсветка вокруг плеера", isOn: s.ambientGlow)
                Toggle("Старые аннотации YouTube", isOn: s.annotations)
                Picker("Источник потоков", selection: s.playbackClient) {
                    Text("Автоматически").tag(Streams.Client.auto)
                    Text("visionOS").tag(Streams.Client.visionos)
                    Text("iOS").tag(Streams.Client.ios)
                }
            }
            Section("Субтитры") {
                Toggle("Включать субтитры", isOn: s.captionsEnabled)
                Picker("Язык субтитров", selection: s.captionsLang) { PairOptions(items: AppSettings.languages) }
                Picker("Размер", selection: s.captionSize) { ForEach(CaptionSize.allCases, id: \.self) { Text($0.title).tag($0) } }
                VStack(alignment: .leading) {
                    Text("Фон: \(Int(app.store.settings.captionBackground * 100))%")
                    Slider(value: s.captionBackground, in: 0...1)
                }
                Toggle("Обводка текста", isOn: s.captionEdge)
                Picker("Цвет текста", selection: s.captionColor) {
                    Text("Белый").tag("ffffff"); Text("Жёлтый").tag("ffe14d"); Text("Голубой").tag("7fdbff")
                }
            }
            sponsorSection
            Section("Скрывать") {
                Toggle("Shorts в лентах", isOn: s.hideShorts)
                Toggle("Трансляции", isOn: s.hideLive)
                Toggle("Анонсы премьер", isOn: s.hideUpcoming)
                Toggle("Просмотренные видео", isOn: s.hideWatched)
                Toggle("Комментарии", isOn: s.hideComments)
                Toggle("Похожие видео", isOn: s.hideRelated)
                Toggle("Описание", isOn: s.hideDescription)
                Toggle("Главы", isOn: s.hideChapters)
                Toggle("Аватары каналов", isOn: s.hideAvatars)
                Toggle("Число просмотров", isOn: s.hideViews)
                Toggle("Категории на главной", isOn: s.hideExplore)
            }
            Section {
                ForEach(app.store.settings.blockedChannels.sorted { $0.value < $1.value }, id: \.key) { e in
                    Text(e.value).swipeActions { Button("Вернуть") { app.store.settings.blockedChannels[e.key] = nil } }
                }
                ForEach(app.store.settings.blockedKeywords, id: \.self) { k in
                    Text("«\(k)»").swipeActions { Button("Убрать") { app.store.settings.blockedKeywords.removeAll { $0 == k } } }
                }
                HStack {
                    TextField("Слово в названии", text: $newKeyword)
                    Button("Добавить") {
                        let k = newKeyword.trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty, !app.store.settings.blockedKeywords.contains(k) { app.store.settings.blockedKeywords.append(k) }
                        newKeyword = ""
                    }
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Фильтр каналов и слов") } footer: { Text("Каналы скрываются через меню «…» у видео. Свайп влево возвращает.") }
            Section("История") {
                Toggle("Записывать историю просмотров", isOn: s.historyEnabled)
                Toggle("Записывать историю поиска", isOn: s.searchHistoryEnabled)
                Button("Очистить историю поиска", role: .destructive) { app.store.library.searchHistory = [] }
            }
            dataSection
            Section("О приложении") {
                LabeledContent("Версия", value: "\(GatewayService.version) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                Link("Исходный код", destination: URL(string: "https://github.com/SteepMans/k-tube-ios")!)
                Text("K-Tube — клиент YouTube без рекламы. Основан на K-Tube для компьютера (форк Stream Tube). SponsorBlock, DeArrow и Return YouTube Dislike — сторонние открытые сервисы.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Настройки")
        .onChange(of: app.store.settings.hl) { _, _ in app.applyRegion() }
        .onChange(of: app.store.settings.gl) { _, _ in app.applyRegion() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .xml, .commaSeparatedText, .plainText, .data]) { r in
            if case .success(let url) = r { doImport(url) }
        }
        .alert("Импорт", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK") {}
        } message: { Text(importResult ?? "") }
        .sheet(item: $exportFile) { f in ShareSheet(items: [f.url]) }
        .confirmationDialog("Удалить ключ с этого iPhone?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Удалить ключ", role: .destructive) { app.forgetKey() }
        }
        .task {
            while !Task.isCancelled {
                stats = app.gateway.stats.get
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var gatewaySection: some View {
        Section {
            HStack {
                Text("Состояние")
                Spacer()
                if checking { ProgressView() }
                else if let info { Label("работает · \(info.rttMs) мс", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
                else if let infoError { Text(infoError).foregroundStyle(.red).font(.callout).multilineTextAlignment(.trailing) }
            }
            LabeledContent("Ключ", value: maskedKey)
            LabeledContent("Соединений сейчас", value: "\(stats.active)")
            LabeledContent("Принято", value: ByteCountFormatter.string(fromByteCount: stats.down, countStyle: .file))
            LabeledContent("Отказов шлюза", value: "\(stats.refused)")
            if case let (date, text)? = app.gateway.lastError.get {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Последняя ошибка").font(.caption).foregroundStyle(.secondary)
                    Text(text).font(.caption)
                    Text(date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button("Проверить шлюз") { Task { await check() } }
            Button("Сменить ключ") { app.pendingKeyLink = "" }
            Button("Удалить ключ", role: .destructive) { confirmForget = true }
        } header: { Text("Внешний шлюз") } footer: {
            Text("Весь трафик к YouTube идёт через внешний прокси-шлюз по вашему ключу. Скорость ограничивает шлюз, поэтому 4K может подгружаться медленно.")
        }
    }

    private var maskedKey: String {
        let t = app.gateway.config.get.token
        return t.count > 10 ? String(t.prefix(5)) + "…" + String(t.suffix(4)) : "нет"
    }

    private var sponsorSection: some View {
        Section {
            Toggle("SponsorBlock", isOn: s.sponsorBlock)
            if app.store.settings.sponsorBlock {
                ForEach(Services.categories, id: \.id) { c in
                    Picker(selection: Binding(get: { app.store.settings.sbActions[c.id] ?? .ignore }, set: { app.store.settings.sbActions[c.id] = $0 })) {
                        ForEach(SegmentAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        HStack { Circle().fill(Color(rgb: c.color)).frame(width: 10, height: 10); Text(c.name) }
                    }
                }
                TextField("Сервер SponsorBlock", text: s.sbServer).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let u = sbUser {
                    LabeledContent("Ваши сегменты", value: "\(u.segments)")
                    LabeledContent("Сэкономлено другим", value: "\(Int(u.minutesSaved)) мин")
                }
            }
            Toggle("DeArrow: честные названия", isOn: s.dearrow)
            Toggle("DeArrow: честные обложки", isOn: s.dearrowThumbnails)
            Toggle("Return YouTube Dislike", isOn: s.returnDislike)
        } header: { Text("SponsorBlock и сервисы сообщества") }
        .task(id: app.store.settings.sponsorBlock) {
            guard app.store.settings.sponsorBlock, !app.store.settings.sbUserId.isEmpty else { return }
            sbUser = try? await app.services.userInfo(server: app.store.settings.sbServer, privateId: app.store.settings.sbUserId)
        }
    }

    private var dataSection: some View {
        Section {
            Button { importing = true } label: { Label("Импорт подписок и истории", systemImage: "square.and.arrow.down") }
            Menu {
                Button("Резервная копия K-Tube (всё)") { export(ImportExport.exportBackup(library: app.store.library, settings: app.store.settings), "ktube-backup.json") }
                Button("Подписки для NewPipe") { export(ImportExport.exportNewPipe(app.store.library.subscriptions), "newpipe-subscriptions.json") }
                Button("Подписки OPML") { export(ImportExport.exportOPML(app.store.library.subscriptions), "subscriptions.opml") }
                Button("Подписки CSV (YouTube)") { export(ImportExport.exportCSV(app.store.library.subscriptions), "subscriptions.csv") }
            } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
        } header: { Text("Данные") } footer: {
            Text("Импорт понимает YouTube Takeout (подписки CSV и историю JSON), NewPipe, FreeTube, OPML и резервную копию K-Tube для компьютера.")
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            info = try await app.gateway.info()
            infoError = nil
        } catch {
            info = nil
            infoError = error.localizedDescription
        }
    }

    private func doImport(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let r = try ImportExport.parse(data, fileName: url.lastPathComponent)
            var parts: [String] = []
            if let lib = r.library {
                app.store.library = lib
                parts.append("библиотека восстановлена")
            }
            if let st = r.settings {
                app.store.settings = st
                app.applyRegion()
                parts.append("настройки восстановлены")
            }
            if !r.subscriptions.isEmpty {
                let n = app.store.library.merge(subscriptions: r.subscriptions)
                parts.append("подписок добавлено: \(n) из \(r.subscriptions.count)")
            }
            if !r.history.isEmpty {
                let n = app.store.library.merge(history: r.history)
                parts.append("записей истории: \(n)")
            }
            importResult = parts.isEmpty ? "В файле ничего не нашлось" : "\(r.format): " + parts.joined(separator: ", ")
            Task { await app.refreshSubsFeed(force: true) }
        } catch {
            importResult = error.localizedDescription
        }
    }

    private func export(_ data: Data, _ name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            exportFile = ExportFile(url: url)
        } catch {
            app.show(error)
        }
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// A (value, title) option; tuples with key paths in ForEach are too slow for the type checker.
struct Pair: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Picker options from a list of (value, title) pairs, tagged by value.
struct PairOptions: View {
    let items: [(String, String)]

    var body: some View {
        ForEach(items.map { Pair(id: $0.0, title: $0.1) }) { (p: Pair) in
            Text(p.title).tag(p.id)
        }
    }
}
