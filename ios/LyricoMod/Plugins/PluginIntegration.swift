// Hooks for features provided by optional packages:
//  - LyricoPlugins (ios/Packages/LyricoPlugins, branch ios-plugins): batch match metadata / lyrics /
//    cover, lyrics search in the editor.
//  - ReplayGain (not ported yet): batch loudness analysis.
// The app shows every registered action; unavailable ones are disabled with an explanatory title.
import Foundation
import SwiftUI
#if canImport(LyricoPlugins)
import LyricoPlugins
#endif

/// One batch action shown in the song list "more" menu for the selected songs.
struct BatchActionDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let isAvailable: Bool
    /// Runs the action. `progress(done, total)` must be called on the main actor.
    let run: @MainActor (_ songs: [SongRecord], _ progress: @escaping @MainActor (Int, Int) -> Void) async -> BatchResult

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct BatchResult {
    var succeeded = 0
    var skipped = 0
    var failed = 0
    var errors: [String] = []
}

@MainActor
final class BatchActionRegistry {
    static let shared = BatchActionRegistry()
    private(set) var actions: [BatchActionDescriptor] = []

    func register(_ action: BatchActionDescriptor) {
        actions.removeAll { $0.id == action.id }
        actions.append(action)
    }

    /// Placeholders so the menu matches Android even before the packages are merged.
    func registerPlaceholders() {
        let unavailable: @MainActor ([SongRecord], @escaping @MainActor (Int, Int) -> Void) async -> BatchResult = { songs, _ in
            BatchResult(skipped: songs.count)
        }
        for (id, key, icon) in [("match_metadata", "action_batch_match_metadata", "text.badge.checkmark"),
                                ("match_lyrics", "action_batch_match_lyrics", "text.quote"),
                                ("match_cover", "action_batch_match_cover", "photo.stack")] where !actions.contains(where: { $0.id == id }) {
            register(BatchActionDescriptor(id: id, title: L(key) + " · " + L("ios_requires_plugins"), systemImage: icon, isAvailable: false, run: unavailable))
        }
        if !actions.contains(where: { $0.id == "replay_gain" }) {
            register(BatchActionDescriptor(id: "replay_gain", title: L("action_batch_replay_gain") + " · " + L("ios_not_ported"), systemImage: "waveform", isAvailable: false, run: unavailable))
        }
    }
}

/// Actions shown in the lyrics editor menu (e.g. "search lyrics" from plugins).
struct LyricsHookAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let isAvailable: Bool
    let run: @MainActor (SongEditorModel) async -> Void
}

@MainActor
final class LyricsHookRegistry {
    static let shared = LyricsHookRegistry()
    var actions: [LyricsHookAction] = []
}

enum PluginIntegration {
    static var isPackageLinked: Bool {
        #if canImport(LyricoPlugins)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    static func register() {
        #if canImport(LyricoPlugins)
        // INTEGRATION: register real actions here, e.g.
        // BatchActionRegistry.shared.register(BatchActionDescriptor(id: "match_lyrics", title: L("action_batch_match_lyrics"),
        //     systemImage: "text.quote", isAvailable: true) { songs, progress in ... use SongFileService.apply(...) ... })
        // LyricsHookRegistry.shared.actions.append(LyricsHookAction(id: "search_lyrics", ...))
        #endif
        BatchActionRegistry.shared.registerPlaceholders()
        if LyricsHookRegistry.shared.actions.isEmpty {
            LyricsHookRegistry.shared.actions.append(LyricsHookAction(
                id: "search_lyrics", title: L("action_search_lyrics") + " · " + L("ios_requires_plugins"),
                systemImage: "magnifyingglass", isAvailable: false, run: { _ in }))
        }
    }
}

/// Generic runner sheet for a registered batch action (progress + result summary).
struct BatchActionRunnerView: View {
    let descriptor: BatchActionDescriptor
    let songIds: [Int64]
    @Environment(\.dismiss) private var dismiss
    @State private var done = 0
    @State private var total = 0
    @State private var result: BatchResult?
    @State private var running = false

    var body: some View {
        List {
            Section {
                Text(descriptor.title)
                if running { ProgressView(value: Double(done), total: Double(max(total, 1))) }
                if let r = result {
                    Text(L("batch_edit_result_summary", r.succeeded, songIds.count, r.skipped, r.failed))
                    ForEach(r.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle(descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("confirm")) { Task { await run() } }.disabled(running || result != nil || !descriptor.isAvailable)
            }
        }
    }

    private func run() async {
        running = true
        let songs = await SongFileService.fetch(ids: songIds)
        total = songs.count
        result = await descriptor.run(songs) { d, t in done = d; total = t }
        running = false
    }
}
