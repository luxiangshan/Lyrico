import PhotosUI
import SwiftUI

/// Batch tag editing (Android BatchEditScreen): only fields switched on are written.
struct BatchEditView: View {
    let songIds: [Int64]
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [SongRecord] = []
    @State private var enabled: Set<AudioTagFieldKey> = []
    @State private var values: [AudioTagFieldKey: String] = [:]
    @State private var cover: PictureUpdate = .unchanged
    @State private var coverPreview: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var running = false
    @State private var done = 0
    @State private var result: BatchResult?

    private let editable: [AudioTagFieldKey] = AudioTagFieldKey.basic + [.composer, .lyricist, .comment, .copyright, .lyrics] + AudioTagFieldKey.replayGain

    var body: some View {
        Form {
            Section {
                Text(L("batch_edit_song_count", songs.count)).foregroundStyle(.secondary)
            }
            Section(L("label_cover")) {
                HStack {
                    if let d = coverPreview, let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $photoItem, matching: .images) { Label(L("batch_edit_cover_change"), systemImage: "photo") }
                        Button(role: .destructive) { cover = .removeFrontCover; coverPreview = nil } label: { Label(L("batch_edit_cover_remove"), systemImage: "trash") }
                        if cover != .unchanged {
                            Button { cover = .unchanged; coverPreview = nil } label: { Label(L("batch_edit_cover_revert"), systemImage: "arrow.uturn.backward") }
                        }
                    }.buttonStyle(.borderless)
                }
                if cover == .removeFrontCover { Text(L("batch_edit_preview_remove_cover")).font(.caption).foregroundStyle(.red) }
            }
            Section(footer: Text(L("ios_batch_edit_hint"))) {
                ForEach(editable, id: \.self) { key in
                    VStack(alignment: .leading) {
                        Toggle(L(key.labelKey), isOn: Binding(get: { enabled.contains(key) }, set: { on in
                            if on { enabled.insert(key) } else { enabled.remove(key) }
                        }))
                        if enabled.contains(key) {
                            TextField(L(key.labelKey), text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }), axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                            if !distinctValues(key).isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(distinctValues(key), id: \.self) { v in
                                            Button(v) { values[key] = v }.buttonStyle(.bordered).controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }
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
        .navigationTitle(L("batch_edit_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(result == nil ? L("cancel") : L("action_close")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("apply_action")) { Task { await apply() } }
                    .disabled(running || result != nil || (enabled.isEmpty && cover == .unchanged))
            }
        }
        .interactiveDismissDisabled(running)
        .task { songs = await SongFileService.fetch(ids: songIds) }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let d = ImageMime.normalizedForTag(data)
                    cover = .replaceFrontCover(data: d, mimeType: ImageMime.detect(d))
                    coverPreview = d
                }
                photoItem = nil
            }
        }
    }

    /// Distinct existing values among the selected songs (Android "select from selected songs").
    private func distinctValues(_ key: AudioTagFieldKey) -> [String] {
        guard key != .lyrics else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for s in songs {
            if let v = key.value(in: s.tagData), !v.isEmpty, !seen.contains(v) {
                seen.insert(v)
                out.append(v)
                if out.count >= 8 { break }
            }
        }
        return out
    }

    private func apply() async {
        running = true
        done = 0
        var r = BatchResult()
        for song in songs {
            var m = AudioTagMutation()
            for key in enabled {
                let v = values[key] ?? ""
                m.fields[key] = v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : .set(v)
            }
            m.pictureUpdate = cover
            do {
                try await SongFileService.apply(m, to: song)
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
