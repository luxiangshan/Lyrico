// Batch match of metadata / lyrics / cover through plugins (Android BatchMatchViewModel +
// MatchMetadataProcessor / MatchLyricsProcessor / MatchCoverProcessor, simplified to one write per song).
#if canImport(LyricoPlugins)
import LyricoPlugins
import SwiftUI

enum BatchMatchKind: String, CaseIterable, Hashable {
    case metadata, lyrics, cover

    var titleKey: String {
        switch self {
        case .metadata: return "action_batch_match_metadata"
        case .lyrics: return "action_batch_match_lyrics"
        case .cover: return "action_batch_match_cover"
        }
    }

    var sourceTypeKey: String {
        switch self {
        case .metadata: return "plugin_type_metadata"
        case .lyrics: return "plugin_type_lyrics"
        case .cover: return "plugin_type_cover"
        }
    }

    var sourceType: PluginSourceType {
        switch self {
        case .metadata: return .metadata
        case .lyrics: return .lyrics
        case .cover: return .cover
        }
    }
}

struct BatchMatchOptions {
    var kinds: Set<BatchMatchKind>
    var overwrite: Bool
    var preferFileName: Bool
    var separator: String
    var lyricConfig: LyricRenderConfig
    var metadataSources: [PluginSearchSource]
    var lyricsSources: [PluginSearchSource]
    var coverSources: [PluginSearchSource]
}

enum SongMatchOutcome {
    case success
    case skipped(String)
    case failed(String)
}

enum BatchMatcher {
    /// Text fields written by metadata matching (Android BatchMatchConfigDefaults.DEFAULT_ENABLED_TARGETS
    /// without lyrics and cover, which have their own options here).
    static let metadataKeys: Set<String> = ["title", "artist", "album", "genre", "date", "track_number"]
    static let metadataMinFinal = 0.76
    static let metadataMinText = 0.72
    static let lyricsMinScore = 0.72
    static let coverMinScore = 0.65

    enum Step<T> {
        case found(T)
        case noMatch
        case noSource
        case error(String)
    }

    static func process(_ song: SongRecord, _ o: BatchMatchOptions) async -> SongMatchOutcome {
        let current: AudioTagData
        do {
            current = try await SongFileService.readTags(song, readPictures: o.kinds.contains(.cover) && !o.overwrite)
        } catch {
            return .failed("\(song.fileName): \(error.localizedDescription)")
        }
        let match = MatchSong(title: current.title ?? song.title, artist: current.artist ?? song.artist,
                              album: current.album ?? song.album, fileName: song.fileName,
                              durationMs: Int64(max(current.durationMilliseconds, song.durationMilliseconds)))
        var edited = current
        var picture: PictureUpdate = .unchanged
        var errors: [String] = []
        var metadataCover: String?

        if o.kinds.contains(.metadata) {
            switch await matchMetadata(match, o) {
            case .found(let fields):
                PluginSearch.apply(fields, keys: metadataKeys, overwrite: o.overwrite, to: &edited)
                metadataCover = fields[PluginSearch.coverKey]
            case .error(let e): errors.append(e)
            default: break
            }
        }
        if Task.isCancelled { return .skipped(song.fileName) }

        if o.kinds.contains(.lyrics), o.overwrite || (current.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch await matchLyrics(match, o) {
            case .found(let text): edited.lyrics = text
            case .error(let e): errors.append(e)
            default: break
            }
        }
        if Task.isCancelled { return .skipped(song.fileName) }

        let hasCover = !current.pictures.isEmpty || (song.hasCover ?? false)
        if o.kinds.contains(.cover), o.overwrite || !hasCover {
            var url: String?
            switch await matchCover(match, o) {
            case .found(let u): url = u
            case .error(let e): errors.append(e)
            default: break
            }
            if url == nil, let metadataCover, !metadataCover.isEmpty { url = metadataCover }
            if let url {
                do {
                    let data = try await PluginSearch.downloadImage(url)
                    picture = .replaceFrontCover(data: data, mimeType: ImageMime.detect(data))
                } catch {
                    errors.append(L("ios_cover_download_failed", error.localizedDescription))
                }
            }
        }
        if Task.isCancelled { return .skipped(song.fileName) }

        let mutation = AudioTagMutation.diff(original: current, edited: edited, pictureUpdate: picture)
        if mutation.isEmpty {
            if !errors.isEmpty { return .failed("\(song.fileName): \(errors.joined(separator: "; "))") }
            return .skipped(song.fileName)
        }
        do {
            try await SongFileService.apply(mutation, to: song, current: current)
            return .success
        } catch {
            return .failed("\(song.fileName): \(error.localizedDescription)")
        }
    }

    // MARK: Metadata (MatchMetadataProcessor)

    static func matchMetadata(_ song: MatchSong, _ o: BatchMatchOptions) async -> Step<StringMap> {
        let sources = o.metadataSources
        guard !sources.isEmpty else { return .noSource }
        let queries = MusicMatch.buildSearchQueries(song, preferFileName: o.preferFileName)
        var best: (result: SongSearchResult, detail: MatchScoreDetail)?
        var attempts = 0, failures = 0
        var lastError = ""
        search: for query in queries {
            for source in sources {
                if Task.isCancelled { return .noMatch }
                attempts += 1
                let results: [SongSearchResult]
                do {
                    results = try await source.searchSongs(keyword: query, page: 1, separator: o.separator, pageSize: 2)
                } catch {
                    failures += 1
                    lastError = "\(source.name): \(error.localizedDescription)"
                    continue
                }
                for (index, r) in results.enumerated() {
                    let d = MusicMatch.score(r, song, preferFileName: o.preferFileName, rankIndex: index)
                    if best == nil || d.finalScore > best!.detail.finalScore { best = (r, d) }
                }
                if let b = best, b.detail.finalScore >= 0.92, b.detail.textScore >= 0.86 { break search }
            }
        }
        guard let b = best else { return attempts > 0 && failures == attempts ? .error(lastError) : .noMatch }
        guard b.detail.finalScore >= metadataMinFinal, b.detail.textScore >= metadataMinText else { return .noMatch }
        return .found(PluginSearch.processedFields(b.result, lyrics: nil, config: o.lyricConfig))
    }

    // MARK: Lyrics (MatchLyricsProcessor)

    static func matchLyrics(_ song: MatchSong, _ o: BatchMatchOptions) async -> Step<String> {
        let sources = o.lyricsSources
        guard !sources.isEmpty else { return .noSource }
        let queries = MusicMatch.buildSearchQueries(song, preferFileName: o.preferFileName)
        let request = SongSearchResult(id: song.fileName, pluginId: "", pluginName: "", title: song.title ?? "",
                                       artist: song.artist ?? "", album: song.album ?? "", duration: song.durationMs)
        var best: (lyrics: LyricsResult, sourceId: String, score: Double)?
        var attempts = 0, failures = 0
        var lastError = ""
        for source in sources {
            if Task.isCancelled { return .noMatch }
            attempts += 1
            do {
                if source.capabilities.contains(.searchSongs) {
                    var results: [SongSearchResult] = []
                    for q in queries { results += try await source.searchSongs(keyword: q, page: 1, separator: o.separator, pageSize: 3) }
                    let scored = results.enumerated().map { ($0.element, MusicMatch.score($0.element, song, preferFileName: o.preferFileName, rankIndex: $0.offset).finalScore) }
                    if let top = scored.max(by: { $0.1 < $1.1 }), top.1 >= lyricsMinScore, top.1 > (best?.score ?? -1),
                       let loaded = try await source.getLyricsCandidates(song: top.0, page: 1, pageSize: 20).first {
                        best = (loaded.lyrics, source.id, top.1)
                    }
                } else {
                    let candidates = try await source.getLyricsCandidates(song: request, page: 1, pageSize: 5)
                    let scored = candidates.enumerated().map { ($0.element, MusicMatch.score($0.element.song, song, preferFileName: o.preferFileName, rankIndex: $0.offset).finalScore) }
                    if let top = scored.max(by: { $0.1 < $1.1 }), top.1 > (best?.score ?? -1) {
                        best = (top.0.lyrics, source.id, top.1)
                    }
                }
            } catch {
                failures += 1
                lastError = "\(source.name): \(error.localizedDescription)"
            }
        }
        guard let b = best else { return attempts > 0 && failures == attempts ? .error(lastError) : .noMatch }
        guard b.score >= lyricsMinScore, let text = PluginSearch.render(b.lyrics, pluginId: b.sourceId, config: o.lyricConfig) else { return .noMatch }
        return .found(text)
    }

    // MARK: Cover (MatchCoverProcessor)

    static func matchCover(_ song: MatchSong, _ o: BatchMatchOptions) async -> Step<String> {
        let sources = o.coverSources
        guard !sources.isEmpty else { return .noSource }
        let request = SongSearchResult(id: song.fileName, pluginId: "", pluginName: "", title: song.title ?? "",
                                       artist: song.artist ?? "", album: song.album ?? "", duration: song.durationMs)
        var best: (url: String, score: Double)?
        var attempts = 0, failures = 0
        var lastError = ""
        for source in sources {
            if Task.isCancelled { return .noMatch }
            attempts += 1
            do {
                let covers = try await source.searchCovers(song: request, page: 1, pageSize: 5).filter { !$0.picUrl.isEmpty }
                for (index, c) in covers.enumerated() {
                    let s = MusicMatch.score(c, song, preferFileName: o.preferFileName, rankIndex: index).finalScore
                    if s > (best?.score ?? -1) { best = (c.picUrl, s) }
                }
            } catch {
                failures += 1
                lastError = "\(source.name): \(error.localizedDescription)"
            }
        }
        guard let b = best else { return attempts > 0 && failures == attempts ? .error(lastError) : .noMatch }
        return b.score >= coverMinScore ? .found(b.url) : .noMatch
    }
}

@MainActor
final class BatchMatchRunner: ObservableObject {
    @Published var done = 0
    @Published var total = 0
    @Published var result = BatchResult()
    @Published var running = false
    @Published var finished = false
    @Published var elapsed: TimeInterval = 0
    private var task: Task<Void, Never>?

    func start(songIds: [Int64], options: BatchMatchOptions, concurrency: Int) {
        guard !running else { return }
        running = true
        finished = false
        result = BatchResult()
        done = 0
        let started = Date()
        task = Task {
            let songs = await SongFileService.fetch(ids: songIds)
            total = songs.count
            await withTaskGroup(of: SongMatchOutcome.self) { group in
                var iterator = songs.makeIterator()
                for _ in 0..<max(1, concurrency) {
                    guard let song = iterator.next() else { break }
                    group.addTask { await BatchMatcher.process(song, options) }
                }
                for await outcome in group {
                    await self.record(outcome)
                    if Task.isCancelled { continue }
                    if let song = iterator.next() {
                        group.addTask { await BatchMatcher.process(song, options) }
                    }
                }
            }
            elapsed = Date().timeIntervalSince(started)
            running = false
            finished = true
            LibraryManager.shared.objectWillChange.send()
        }
    }

    func cancel() { task?.cancel() }

    private func record(_ outcome: SongMatchOutcome) {
        done += 1
        switch outcome {
        case .success: result.succeeded += 1
        case .skipped: result.skipped += 1
        case .failed(let message):
            result.failed += 1
            if result.errors.count < 50 { result.errors.append(message) }
        }
    }
}

@MainActor
struct BatchMatchView: View {
    let songIds: [Int64]
    @State private var kinds: Set<BatchMatchKind>
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var runner = BatchMatchRunner()
    @Environment(\.dismiss) private var dismiss

    init(songIds: [Int64], initialKinds: Set<BatchMatchKind>) {
        self.songIds = songIds
        _kinds = State(initialValue: initialKinds)
    }

    var body: some View {
        Form {
            if !runner.running && !runner.finished {
                Section {
                    ForEach(BatchMatchKind.allCases, id: \.self) { kind in
                        let count = PluginManager.shared.sources(for: kind.sourceType).count
                        Toggle(isOn: Binding(get: { kinds.contains(kind) }, set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(kind.titleKey))
                                Text(count == 0 ? L("plugin_type_empty", L(kind.sourceTypeKey)) : "\(L(kind.sourceTypeKey)) × \(count)")
                                    .font(.caption).foregroundColor(count == 0 ? Color.red : Color.secondary)
                            }
                        }
                    }
                } header: { Text(L("ios_batch_match_what")) } footer: {
                    if kinds.contains(.metadata) { Text(L("ios_batch_match_metadata_fields")) }
                }
                Section {
                    toggle("batch_match_overwrite_mode", "batch_match_overwrite_mode_summary", $settings.batchMatchOverwrite)
                    toggle("batch_match_prefer_filename", "batch_match_prefer_filename_summary", $settings.batchMatchPreferFileName)
                    Stepper(value: $settings.batchMatchConcurrency, in: 1...4) {
                        Text("\(L("batch_match_config_concurrency"))：\(settings.batchMatchConcurrency)")
                    }
                }
                Section {
                    Text(L("selection_mode_selected_count", songIds.count)).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ProgressView(value: Double(runner.done), total: Double(max(runner.total, 1)))
                    Text("\(runner.done) / \(runner.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(L("batch_match_stat_format", runner.result.succeeded, runner.result.failed, runner.result.skipped))
                    if runner.finished {
                        Text(L("batch_matching_total_time", runner.elapsed)).foregroundStyle(.secondary)
                    }
                }
                if !runner.result.errors.isEmpty {
                    Section(L("ios_errors")) {
                        ForEach(runner.result.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .navigationTitle(L("batch_matching_title"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(runner.running)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if runner.running {
                    Button(L("action_abort"), role: .destructive) { runner.cancel() }
                } else {
                    Button(L("action_close")) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if !runner.running && !runner.finished {
                    Button(L("confirm")) { start() }.disabled(kinds.isEmpty || songIds.isEmpty)
                }
            }
        }
        .onDisappear { runner.cancel() }
    }

    private func toggle(_ title: String, _ hint: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title))
                Text(L(hint)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        let manager = PluginManager.shared
        let options = BatchMatchOptions(
            kinds: kinds,
            overwrite: settings.batchMatchOverwrite,
            preferFileName: settings.batchMatchPreferFileName,
            separator: settings.multiValueSeparator,
            lyricConfig: settings.lyricRenderConfig,
            metadataSources: kinds.contains(.metadata) ? manager.sources(for: .metadata) : [],
            lyricsSources: kinds.contains(.lyrics) ? manager.sources(for: .lyrics) : [],
            coverSources: kinds.contains(.cover) ? manager.sources(for: .cover) : []
        )
        runner.start(songIds: songIds, options: options, concurrency: settings.batchMatchConcurrency)
    }
}
#endif
