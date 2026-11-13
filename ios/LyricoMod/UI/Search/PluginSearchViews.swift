// Editor search screens backed by plugins (Android SearchResultsScreen / SearchLyricsScreen / SearchCoverScreen).
#if canImport(LyricoPlugins)
import LyricoPlugins
import SwiftUI

// MARK: - Shared multi-source search state

@MainActor
final class MultiSourceSearch<Item>: ObservableObject {
    typealias Fetch = (PluginSearchSource, String, Int) async throws -> [Item]

    let sources: [PluginSearchSource]
    private let fetch: Fetch
    private let key: (Item) -> String

    @Published var results: [String: [Item]] = [:]
    @Published var loading: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var hasMore: [String: Bool] = [:]
    @Published var selected: String?
    private var pages: [String: Int] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var keyword = ""
    private var generation = 0

    init(sources: [PluginSearchSource], key: @escaping (Item) -> String, fetch: @escaping Fetch) {
        self.sources = sources
        self.key = key
        self.fetch = fetch
        self.selected = sources.first?.id
    }

    var selectedSource: PluginSearchSource? { sources.first { $0.id == selected } }

    func search(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        self.keyword = kw
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        results = [:]; errors = [:]; hasMore = [:]; pages = [:]; loading = []
        for s in sources { load(s, page: 1) }
    }

    func loadMore(_ id: String) {
        guard let s = sources.first(where: { $0.id == id }), !loading.contains(id) else { return }
        load(s, page: (pages[id] ?? 1) + 1)
    }

    func cancelAll() { tasks.values.forEach { $0.cancel() } }

    private func load(_ source: PluginSearchSource, page: Int) {
        let id = source.id, kw = keyword, gen = generation, fetch = self.fetch
        loading.insert(id)
        errors[id] = nil
        tasks[id] = Task { [weak self] in
            do {
                let items = try await fetch(source, kw, page)
                guard let self, self.generation == gen else { return }
                var list = page == 1 ? [] : (self.results[id] ?? [])
                let known = Set(list.map(self.key))
                let fresh = items.filter { !known.contains(self.key($0)) }
                list += fresh
                self.results[id] = list
                self.pages[id] = page
                self.hasMore[id] = !fresh.isEmpty
                self.loading.remove(id)
            } catch {
                guard let self, self.generation == gen else { return }
                if !(error is CancellationError) { self.errors[id] = error.localizedDescription }
                self.loading.remove(id)
            }
        }
    }
}

struct SourceTabBar: View {
    let sources: [PluginSearchSource]
    @Binding var selected: String?
    let count: (String) -> Int?
    let isLoading: (String) -> Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources, id: \.id) { s in
                    Button { selected = s.id } label: {
                        HStack(spacing: 4) {
                            Text(s.name).lineLimit(1)
                            if isLoading(s.id) {
                                ProgressView().controlSize(.mini)
                            } else if let c = count(s.id) {
                                Text("\(c)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selected == s.id ? Color.accentColor.opacity(0.22) : Color(.secondarySystemFill)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

struct SearchKeywordBar: View {
    @Binding var keyword: String
    let placeholder: String
    let onSubmit: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !keyword.isEmpty {
                Button { keyword = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            Button(L("action_search"), action: onSubmit).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
        .padding(.horizontal)
        .padding(.top, 6)
    }
}

struct NoSourcesView: View {
    let typeKey: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
            Text(L("plugin_type_empty", L(typeKey))).font(.headline)
            Text(L("ios_no_sources_hint")).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Status rows (loading / error / empty / load more) below a source's results.
struct SourceStatusRows: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let hasMore: Bool
    let loaded: Bool
    let retry: () -> Void
    let loadMore: () -> Void

    var body: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else if let error {
            VStack(alignment: .leading, spacing: 6) {
                Text(isEmpty ? L("load_failed") : L("search_load_more_failed")).foregroundStyle(.red)
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button(L("refresh"), action: isEmpty ? retry : loadMore)
            }
        } else if isEmpty && loaded {
            Text(L("search_no_results")).foregroundStyle(.secondary)
        } else if hasMore {
            Button(L("search_load_more"), action: loadMore)
        }
    }
}

@MainActor
private func initialKeyword(_ model: SongEditorModel) -> String {
    let title = model.edited.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let artist = model.edited.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let kw = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
    if !kw.isEmpty { return kw }
    return ((model.target?.fileName ?? "") as NSString).deletingPathExtension
}

private struct ResultThumb: View {
    let url: String
    var size: CGFloat = 48
    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.secondarySystemFill)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SongResultRow: View {
    let song: SongSearchResult
    var body: some View {
        HStack(spacing: 12) {
            ResultThumb(url: song.picUrl)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title.isEmpty ? "-" : song.title).lineLimit(1)
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let extra = [song.duration > 0 ? Format.duration(ms: Int(song.duration)) : "", song.date].filter { !$0.isEmpty }
                if !extra.isEmpty {
                    Text(extra.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Metadata search

@MainActor
struct MetadataSearchView: View {
    @ObservedObject var model: SongEditorModel
    @StateObject private var search: MultiSourceSearch<SongSearchResult>
    @State private var keyword: String
    @State private var picked: SongSearchResult?
    @Environment(\.dismiss) private var dismiss

    init(model: SongEditorModel) {
        self.model = model
        let sources = PluginManager.shared.sources(for: .metadata)
        let separator = AppSettings.shared.multiValueSeparator
        let pageSize = max(1, AppSettings.shared.searchPageSize)
        _search = StateObject(wrappedValue: MultiSourceSearch<SongSearchResult>(sources: sources, key: { $0.pluginId + "|" + $0.id }) { source, kw, page in
            try await source.searchSongs(keyword: kw, page: page, separator: separator, pageSize: pageSize)
        })
        _keyword = State(initialValue: initialKeyword(model))
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchKeywordBar(keyword: $keyword, placeholder: L("search_main_placeholder")) { search.search(keyword) }
            if search.sources.isEmpty {
                NoSourcesView(typeKey: "plugin_type_metadata")
            } else {
                SourceTabBar(sources: search.sources, selected: $search.selected,
                             count: { search.results[$0]?.count }, isLoading: { search.loading.contains($0) })
                list
            }
        }
        .navigationTitle(L("ios_search_metadata"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } } }
        .task { if search.results.isEmpty && search.loading.isEmpty { search.search(keyword) } }
        .onDisappear { search.cancelAll() }
        .sheet(item: $picked) { result in
            NavigationStack {
                MetadataApplyView(result: result, source: search.sources.first { $0.id == result.pluginId } ?? search.selectedSource, model: model) {
                    picked = nil
                    dismiss()
                }
            }
        }
    }

    private var list: some View {
        List {
            if let id = search.selected {
                let items = search.results[id] ?? []
                ForEach(items) { song in
                    Button { picked = song } label: { SongResultRow(song: song) }.buttonStyle(.plain)
                }
                SourceStatusRows(isLoading: search.loading.contains(id), error: search.errors[id], isEmpty: items.isEmpty,
                                 hasMore: search.hasMore[id] ?? false, loaded: search.results[id] != nil,
                                 retry: { search.search(keyword) }, loadMore: { search.loadMore(id) })
            }
        }
        .listStyle(.plain)
    }
}

/// Preview of one result's fields with per-field selection; apply fills the editor (user saves as usual).
@MainActor
struct MetadataApplyView: View {
    let result: SongSearchResult
    let source: PluginSearchSource?
    @ObservedObject var model: SongEditorModel
    let onApplied: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var fields = StringMap()
    @State private var selected: Set<String> = []
    @State private var lyricsText: String?
    @State private var lyricsState: LoadState = .idle
    @State private var supplement = false
    @State private var applying = false

    enum LoadState { case idle, loading, failed, done }

    var body: some View {
        Form {
            Section {
                Toggle(L("ios_only_fill_empty"), isOn: $supplement)
            } footer: { Text(L("batch_match_overwrite_mode_summary")) }
            Section(L("search_apply_tab_metadata")) {
                ForEach(PluginSearch.orderedKeys(fields).filter { $0 != PluginSearch.lyricsKey }, id: \.self) { key in
                    row(key)
                }
            }
            if source.map(PluginSearch.supportsLyrics) == true {
                Section(L("label_lyrics")) {
                    switch lyricsState {
                    case .loading: HStack { ProgressView(); Text(L("lyrics_loading")).foregroundStyle(.secondary) }
                    case .failed: Text(L("fetch_lyrics_failed")).foregroundStyle(.secondary)
                    default:
                        if fields[PluginSearch.lyricsKey] != nil { row(PluginSearch.lyricsKey) } else { Text(L("lyrics_empty")).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle(result.title.isEmpty ? L("apply_action") : result.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
            ToolbarItem(placement: .principal) {
                Button(selected.isEmpty ? L("action_select_all") : L("action_deselect_all")) {
                    selected = selected.isEmpty ? Set(fields.keys) : []
                }.font(.subheadline)
            }
            ToolbarItem(placement: .confirmationAction) {
                if applying { ProgressView() } else {
                    Button(L("apply_action")) { Task { await apply() } }.disabled(selected.isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private func row(_ key: String) -> some View {
        let value = fields[key] ?? ""
        let on = Binding(get: { selected.contains(key) }, set: { if $0 { selected.insert(key) } else { selected.remove(key) } })
        return Toggle(isOn: on) {
            if key == PluginSearch.coverKey {
                HStack {
                    Text(L("label_cover"))
                    Spacer()
                    ResultThumb(url: value, size: 64)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PluginSearch.label(forKey: key)).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(key == PluginSearch.lyricsKey ? .caption.monospaced() : .body)
                        .lineLimit(key == PluginSearch.lyricsKey ? 12 : 4)
                    let current = PluginSearch.editorKey(key).flatMap { $0.value(in: model.edited) } ?? ""
                    if !current.isEmpty && current != value && key != PluginSearch.lyricsKey {
                        Text(current).font(.caption2).strikethrough(!supplement).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func recompute() {
        let config = settings.lyricRenderConfig
        let new = PluginSearch.processedFields(result, lyrics: lyricsText, config: config)
        let newKeys = Set(new.keys).subtracting(fields.keys)
        fields = new
        selected.formUnion(newKeys)
    }

    private func load() async {
        recompute()
        guard let source, PluginSearch.supportsLyrics(source), lyricsState == .idle else { return }
        lyricsState = .loading
        do {
            if let lyrics = try await PluginSearch.fetchLyrics(result, source: source) {
                lyricsText = PluginSearch.render(lyrics, pluginId: source.id, config: settings.lyricRenderConfig)
            }
            lyricsState = .done
            recompute()
        } catch {
            lyricsState = .failed
        }
    }

    private func apply() async {
        var data = model.edited
        PluginSearch.apply(fields, keys: selected, overwrite: !supplement, to: &data)
        model.edited = data
        if selected.contains(PluginSearch.coverKey), let url = fields[PluginSearch.coverKey], !supplement || model.coverData == nil {
            applying = true
            do {
                model.setCover(try await PluginSearch.downloadImage(url))
            } catch {
                applying = false
                model.message = BannerMessage(text: L("ios_cover_download_failed", error.localizedDescription), isError: true)
                onApplied()
                return
            }
            applying = false
        }
        model.message = BannerMessage(text: L("ios_applied_to_editor"))
        onApplied()
    }
}

// MARK: - Lyrics search

struct LyricsCandidateItem: Identifiable {
    let song: SongSearchResult
    let lyrics: LyricsResult?
    var id: String { song.pluginId + "|" + song.id }
}

@MainActor
struct LyricsSearchView: View {
    @ObservedObject var model: SongEditorModel
    @StateObject private var search: MultiSourceSearch<LyricsCandidateItem>
    @State private var keyword: String
    @State private var picked: LyricsCandidateItem?
    @Environment(\.dismiss) private var dismiss

    init(model: SongEditorModel) {
        self.model = model
        let sources = PluginManager.shared.sources(for: .lyrics)
        let separator = AppSettings.shared.multiValueSeparator
        let pageSize = max(1, AppSettings.shared.searchPageSize)
        let initial = initialKeyword(model)
        let request = SongSearchResult(id: "local", pluginId: "", pluginName: "",
                                       title: model.edited.title ?? "", artist: model.edited.artist ?? "",
                                       album: model.edited.album ?? "", duration: Int64(model.original.durationMilliseconds),
                                       date: model.edited.date ?? "")
        _search = StateObject(wrappedValue: MultiSourceSearch<LyricsCandidateItem>(sources: sources, key: { $0.id }) { source, kw, page in
            if source.capabilities.contains(.searchSongs) {
                return try await source.searchSongs(keyword: kw, page: page, separator: separator, pageSize: pageSize)
                    .map { LyricsCandidateItem(song: $0, lyrics: nil) }
            }
            var req = request
            if kw != initial || (req.title.isEmpty && req.artist.isEmpty) {
                req.title = kw; req.artist = ""; req.album = ""; req.date = ""
            }
            return try await source.getLyricsCandidates(song: req, page: page, pageSize: pageSize)
                .map { LyricsCandidateItem(song: $0.song, lyrics: $0.lyrics) }
        })
        _keyword = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchKeywordBar(keyword: $keyword, placeholder: L("search_lyrics_placeholder")) { search.search(keyword) }
            if search.sources.isEmpty {
                NoSourcesView(typeKey: "plugin_type_lyrics")
            } else {
                SourceTabBar(sources: search.sources, selected: $search.selected,
                             count: { search.results[$0]?.count }, isLoading: { search.loading.contains($0) })
                List {
                    if let id = search.selected {
                        let items = search.results[id] ?? []
                        ForEach(items) { item in
                            Button { picked = item } label: { SongResultRow(song: item.song) }.buttonStyle(.plain)
                        }
                        SourceStatusRows(isLoading: search.loading.contains(id), error: search.errors[id], isEmpty: items.isEmpty,
                                         hasMore: search.hasMore[id] ?? false, loaded: search.results[id] != nil,
                                         retry: { search.search(keyword) }, loadMore: { search.loadMore(id) })
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L("action_search_lyrics"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } } }
        .task { if search.results.isEmpty && search.loading.isEmpty { search.search(keyword) } }
        .onDisappear { search.cancelAll() }
        .sheet(item: $picked) { item in
            NavigationStack {
                LyricsPreviewView(item: item, source: search.sources.first { $0.id == item.song.pluginId } ?? search.selectedSource, model: model) {
                    picked = nil
                    dismiss()
                }
            }
        }
    }
}

@MainActor
struct LyricsPreviewView: View {
    let item: LyricsCandidateItem
    let source: PluginSearchSource?
    @ObservedObject var model: SongEditorModel
    let onApplied: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: LyricsResult?
    @State private var text: String?
    @State private var loading = true
    @State private var failed: String?

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 8) { ProgressView(); Text(L("lyrics_loading")).foregroundStyle(.secondary) }
            } else if let text {
                ScrollView {
                    Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            } else {
                VStack(spacing: 8) {
                    Text(failed == nil ? L("lyrics_empty") : L("fetch_lyrics_failed")).foregroundStyle(.secondary)
                    if let failed { Text(failed).font(.caption).foregroundStyle(.secondary) }
                }.padding()
            }
        }
        .navigationTitle(item.song.title.isEmpty ? L("label_lyrics") : item.song.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("apply_action")) {
                    model.edited.lyrics = text
                    model.message = BannerMessage(text: L("ios_applied_to_editor"))
                    onApplied()
                }.disabled(text == nil)
            }
            ToolbarItem(placement: .bottomBar) {
                Text("\(L(LyricFormat(rawValue: settings.lyricFormat)?.labelKey ?? "lyric_format_verbatim")) · \(item.song.pluginName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await load() }
        .onChange(of: settings.lyricRenderConfig) { _ in rerender() }
    }

    private func rerender() {
        guard let lyrics else { return }
        text = PluginSearch.render(lyrics, pluginId: item.song.pluginId.isEmpty ? (source?.id ?? "") : item.song.pluginId, config: settings.lyricRenderConfig)
    }

    private func load() async {
        defer { loading = false }
        if let l = item.lyrics {
            lyrics = l
        } else if let source {
            do { lyrics = try await PluginSearch.fetchLyrics(item.song, source: source) } catch { failed = error.localizedDescription }
        }
        rerender()
    }
}

// MARK: - Cover search

@MainActor
struct CoverSearchView: View {
    @ObservedObject var model: SongEditorModel
    @StateObject private var search: MultiSourceSearch<SongSearchResult>
    @State private var keyword: String
    @State private var downloading: String?
    @Environment(\.dismiss) private var dismiss

    init(model: SongEditorModel) {
        self.model = model
        let sources = PluginManager.shared.sources(for: .cover)
        let pageSize = max(1, AppSettings.shared.searchPageSize)
        _search = StateObject(wrappedValue: MultiSourceSearch<SongSearchResult>(sources: sources, key: { $0.picUrl }) { source, kw, page in
            try await source.searchCovers(keyword: kw, page: page, pageSize: pageSize).filter { !$0.picUrl.isEmpty }
        })
        _keyword = State(initialValue: initialKeyword(model))
    }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            SearchKeywordBar(keyword: $keyword, placeholder: L("search_cover_placeholder")) { search.search(keyword) }
            if search.sources.isEmpty {
                NoSourcesView(typeKey: "plugin_type_cover")
            } else {
                SourceTabBar(sources: search.sources, selected: $search.selected,
                             count: { search.results[$0]?.count }, isLoading: { search.loading.contains($0) })
                ScrollView {
                    if let id = search.selected {
                        let items = search.results[id] ?? []
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(items, id: \.picUrl) { cover in
                                Button { Task { await pick(cover) } } label: { cell(cover) }
                                    .buttonStyle(.plain)
                                    .disabled(downloading != nil)
                            }
                        }
                        .padding(.horizontal)
                        VStack {
                            SourceStatusRows(isLoading: search.loading.contains(id), error: search.errors[id], isEmpty: items.isEmpty,
                                             hasMore: search.hasMore[id] ?? false, loaded: search.results[id] != nil,
                                             retry: { search.search(keyword) }, loadMore: { search.loadMore(id) })
                        }
                        .padding()
                    }
                }
            }
        }
        .navigationTitle(L("action_search_cover"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } } }
        .task { if search.results.isEmpty && search.loading.isEmpty { search.search(keyword) } }
        .onDisappear { search.cancelAll() }
    }

    private func cell(_ cover: SongSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    AsyncImage(url: URL(string: cover.picUrl)) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                )
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if downloading == cover.picUrl {
                        ZStack { Color.black.opacity(0.4); ProgressView().tint(.white) }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            Text(cover.title.isEmpty ? " " : cover.title).font(.caption).lineLimit(1)
            Text(cover.artist.isEmpty ? " " : cover.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func pick(_ cover: SongSearchResult) async {
        downloading = cover.picUrl
        defer { downloading = nil }
        do {
            model.setCover(try await PluginSearch.downloadImage(cover.picUrl))
            model.message = BannerMessage(text: L("ios_applied_to_editor"))
            dismiss()
        } catch {
            model.message = BannerMessage(text: L("ios_cover_download_failed", error.localizedDescription), isError: true)
        }
    }
}

/// Which plugin search sheet the editor shows.
enum EditorSearchSheet: String, Identifiable {
    case metadata, lyrics, cover
    var id: String { rawValue }
}

@MainActor
struct EditorSearchSheetView: View {
    let kind: EditorSearchSheet
    @ObservedObject var model: SongEditorModel

    var body: some View {
        NavigationStack {
            switch kind {
            case .metadata: MetadataSearchView(model: model)
            case .lyrics: LyricsSearchView(model: model)
            case .cover: CoverSearchView(model: model)
            }
        }
    }
}
#endif
