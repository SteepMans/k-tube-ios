import SwiftUI

struct SearchView: View {
    @EnvironmentObject var app: AppModel
    var initial: String = ""
    @State private var query = ""
    @State private var submitted = ""
    @State private var suggestions: [String] = []
    @State private var items: [Item] = []
    @State private var continuation: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var filter = SearchFilter()
    @State private var showFilters = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            if submitted.isEmpty || focused {
                suggestionList
            } else if loading && items.isEmpty {
                ProgressView().padding(.top, 60)
            } else if let error, items.isEmpty {
                ErrorState(text: error) { Task { await search(submitted) } }
            } else if items.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Ничего не нашлось", text: "Попробуйте другие слова или сбросьте фильтры")
            } else {
                Feed(items: items, compact: true, loadingMore: loadingMore) { Task { await more() } }
                    .padding(.top, 8)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск или ссылка YouTube")
        .searchFocused($focused)
        .onSubmit(of: .search) { Task { await search(query) } }
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showFilters) {
            SearchFilters(filter: $filter) {
                if !submitted.isEmpty { Task { await search(submitted) } }
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { suggestions = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            suggestions = (try? await app.innertube.suggestions(q)) ?? []
        }
        .onAppear {
            if !initial.isEmpty && submitted.isEmpty {
                query = initial
                Task { await search(initial) }
            } else if initial.isEmpty && submitted.isEmpty {
                focused = true
            }
        }
    }

    private var suggestionList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            let recent = app.store.library.searchHistory.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(query.isEmpty ? 15 : 4)
            ForEach(Array(recent), id: \.self) { s in
                row(s, icon: "clock.arrow.circlepath") {
                    Button { app.store.library.searchHistory.removeAll { $0 == s } } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            ForEach(suggestions.filter { s in !recent.contains(s) }, id: \.self) { s in
                row(s, icon: "magnifyingglass") {
                    Button { query = s + " " } label: { Image(systemName: "arrow.up.left").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row<T: View>(_ s: String, icon: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(s).lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            query = s
            Task { await search(s) }
        }
    }

    private func search(_ q: String) async {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focused = false
        if Innertube.parseYouTubeURL(text) != nil || (text.hasPrefix("http") && text.contains("youtu")) {
            app.openLink(text)
            return
        }
        submitted = text
        if app.store.settings.searchHistoryEnabled { app.store.library.recordSearch(text) }
        loading = true
        error = nil
        items = []
        defer { loading = false }
        do {
            let p = try await app.innertube.search(text, filter: filter)
            items = app.filtered(p.items)
            continuation = p.continuation
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func more() async {
        guard let t = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let p = try? await app.innertube.searchContinue(t) {
            let seen = Set(items.map(\.id))
            items += app.filtered(p.items).filter { !seen.contains($0.id) }
            continuation = p.continuation
        }
    }
}

struct SearchFilters: View {
    @Binding var filter: SearchFilter
    var apply: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Сортировка", selection: $filter.sort) {
                    Text("По релевантности").tag(0); Text("По рейтингу").tag(1); Text("По дате").tag(2); Text("По просмотрам").tag(3)
                }
                Picker("Дата загрузки", selection: $filter.date) {
                    Text("Любая").tag(0); Text("За час").tag(1); Text("Сегодня").tag(2); Text("За неделю").tag(3); Text("За месяц").tag(4); Text("За год").tag(5)
                }
                Picker("Тип", selection: $filter.kind) {
                    Text("Все").tag(0); Text("Видео").tag(1); Text("Каналы").tag(2); Text("Плейлисты").tag(3); Text("Фильмы").tag(4)
                }
                Picker("Длительность", selection: $filter.duration) {
                    Text("Любая").tag(0); Text("До 4 минут").tag(1); Text("4–20 минут").tag(3); Text("Больше 20 минут").tag(2)
                }
                Section("Особенности") {
                    Toggle("Прямой эфир", isOn: $filter.live)
                    Toggle("HD", isOn: $filter.hd)
                    Toggle("4K", isOn: $filter.fourK)
                    Toggle("HDR", isOn: $filter.hdr)
                    Toggle("Субтитры", isOn: $filter.subtitles)
                    Toggle("Creative Commons", isOn: $filter.creativeCommons)
                }
                Button("Сбросить фильтры", role: .destructive) { filter = SearchFilter() }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        apply()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
