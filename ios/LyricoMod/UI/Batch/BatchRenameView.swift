import SwiftUI

/// Batch rename by pattern (Android BatchRenameScreen + FormatParser: @1 title, @2 artist,
/// @3 album artist, @4 album, @5 track, @6 disc, @7 year, @8 genre).
struct BatchRenameView: View {
    let songIds: [Int64]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var songs: [SongRecord] = []
    @State private var format = ""
    @State private var running = false
    @State private var done = 0
    @State private var result: BatchResult?

    enum TagField: Int, CaseIterable {
        case title = 1, artist, albumArtist, album, track, disc, year, genre
        var labelKey: String {
            switch self {
            case .title: return "label_title"
            case .artist: return "label_artists"
            case .albumArtist: return "label_album_artist"
            case .album: return "label_album"
            case .track: return "label_track_number"
            case .disc: return "label_disc_number"
            case .year: return "label_year"
            case .genre: return "label_genre"
            }
        }
        func value(_ s: SongRecord) -> String? {
            switch self {
            case .title: return s.title
            case .artist: return s.artist
            case .albumArtist: return s.albumArtist
            case .album: return s.album
            case .track: return s.trackerNumber
            case .disc: return s.discNumber.map(String.init)
            case .year: return s.date
            case .genre: return s.genre
            }
        }
    }

    static func buildName(format: String, song: SongRecord) -> String {
        guard let regex = try? NSRegularExpression(pattern: "@(\\d+)") else { return format }
        let ns = format as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: format, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let idx = Int(ns.substring(with: m.range(at: 1))) ?? -1
            if let field = TagField(rawValue: idx) {
                out += field.value(song) ?? ""
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return SongFileService.sanitizeFileName(out)
    }

    struct Preview: Identifiable {
        let song: SongRecord
        let name: String
        var id: Int64 { song.id ?? -1 }
    }

    private var previews: [Preview] {
        songs.map { s in
            let ext = (s.fileName as NSString).pathExtension
            let base = Self.buildName(format: format, song: s)
            return Preview(song: s, name: base.isEmpty ? s.fileName : (ext.isEmpty ? base : "\(base).\(ext)"))
        }
    }

    private var hasConflicts: Bool {
        var seen = Set<String>()
        for p in previews {
            let key = "\(p.song.folderId)|\(p.song.directory)|\(p.name.lowercased())"
            if seen.contains(key) { return true }
            seen.insert(key)
        }
        return false
    }

    var body: some View {
        Form {
            Section(header: Text(L("rename_format")), footer: Text(L("format_hint"))) {
                TextField("@1 - @2", text: $format)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(TagField.allCases, id: \.rawValue) { f in
                            Button("@\(f.rawValue) \(L(f.labelKey))") { format += "@\(f.rawValue)" }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            if hasConflicts {
                Section { Text(L("rename_conflict_warning")).foregroundStyle(.orange) }
            }
            Section(L("preview_title")) {
                ForEach(previews) { p in
                    let song = p.song, name = p.name
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("label_old_name", song.fileName)).font(.caption).foregroundStyle(.secondary)
                        Text(L("label_new_name") + ": " + name).font(.callout)
                            .foregroundStyle(name == song.fileName ? Color.secondary : Color.primary)
                    }
                }
            }
            if running || result != nil {
                Section {
                    if running { ProgressView(value: Double(done), total: Double(max(songs.count, 1))) }
                    if let r = result {
                        Text(L("batch_edit_result_summary", r.succeeded, songs.count, r.skipped, r.failed))
                        ForEach(r.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .navigationTitle(L("batch_rename_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(result == nil ? L("cancel") : L("action_close")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("action_rename")) { Task { await run() } }.disabled(running || result != nil || format.isEmpty)
            }
        }
        .interactiveDismissDisabled(running)
        .task {
            if format.isEmpty { format = settings.renameFormat }
            songs = await SongFileService.fetch(ids: songIds)
        }
    }

    private func run() async {
        settings.renameFormat = format
        running = true
        var r = BatchResult()
        for p in previews {
            let song = p.song, name = p.name
            if name == song.fileName { r.skipped += 1; done += 1; continue }
            do {
                try await SongFileService.rename(song, to: name)
                r.succeeded += 1
            } catch {
                r.failed += 1
                r.errors.append("\(song.fileName): \(error.localizedDescription)")
            }
            done += 1
        }
        result = r
        running = false
    }
}
