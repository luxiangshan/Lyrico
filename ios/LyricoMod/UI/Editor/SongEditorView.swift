import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Song detail / tag editor (Android EditMetadataScreen).
struct SongEditorView: View {
    let songId: Int64
    @StateObject private var model = SongEditorModel()

    var body: some View {
        TagEditorForm(model: model)
            .task { await model.load(songId: songId) }
    }
}

/// Editor for a file opened from another app (no library entry).
struct ExternalFileEditorView: View {
    let url: URL
    @StateObject private var model = SongEditorModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TagEditorForm(model: model)
            .task { await model.load(url: url) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } }
            }
    }
}

struct TagEditorForm: View {
    @ObservedObject var model: SongEditorModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showImageImporter = false
    @State private var share: ShareItems?
    @State private var showAddCustom = false
    @State private var newCustomKey = ""
    @State private var newCustomValue = ""
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        Group {
            if model.isLoading && model.target == nil {
                ProgressView()
            } else if let error = model.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(error).multilineTextAlignment(.center)
                    Button(L("refresh")) { Task { await model.reload() } }
                }.padding()
            } else {
                form
            }
        }
        .navigationTitle(model.edited.title?.isEmpty == false ? model.edited.title! : L("edit_metadata_default_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button(L("source_config_save")) { Task { await model.save() } }
                        .disabled(!model.hasChanges)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                Button { model.revert() } label: { Label(L("action_undo_changes"), systemImage: "arrow.uturn.backward") }
                    .disabled(!model.hasChanges)
                if let song = model.song {
                    Button {
                        renameText = (song.fileName as NSString).deletingPathExtension
                        showRename = true
                    } label: { Label(L("menu_action_rename"), systemImage: "pencil") }
                    Button {
                        Task {
                            let urls = await SongFileService.shareableURLs([song])
                            if !urls.isEmpty { share = ShareItems(items: urls) }
                        }
                    } label: { Label(L("menu_action_share"), systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { model.setCover(ImageMime.normalizedForTag(data)) }
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.setCover(ImageMime.normalizedForTag(data))
                }
                photoItem = nil
            }
        }
        .alert(L("dialog_rename_title"), isPresented: $showRename) {
            TextField(L("label_new_name", "").trimmingCharacters(in: CharacterSet(charactersIn: "：: ")), text: $renameText)
            Button(L("cancel"), role: .cancel) {}
            Button(L("confirm")) {
                guard let song = model.song else { return }
                let name = renameText
                Task {
                    do {
                        let updated = try await SongFileService.rename(song, to: name)
                        model.target = .song(updated)
                    } catch {
                        model.message = BannerMessage(text: error.localizedDescription, isError: true)
                    }
                }
            }
        }
        .alert(L("action_add_custom_tag"), isPresented: $showAddCustom) {
            TextField(L("custom_tag_key"), text: $newCustomKey).textInputAutocapitalization(.characters)
            TextField(L("label_custom_tag_value"), text: $newCustomValue)
            Button(L("cancel"), role: .cancel) {}
            Button(L("confirm")) { addCustomTag() }
        } message: { Text(L("custom_tag_key_hint")) }
        .banner($model.message)
    }

    private var form: some View {
        Form {
            coverSection
            Section(L("group_basic_info")) {
                ForEach(AudioTagFieldKey.basic, id: \.self) { key in field(key) }
            }
            Section(L("label_lyrics")) {
                NavigationLink {
                    LyricsEditorView(model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("label_lyrics"))
                        Text(lyricsPreview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            Section(L("group_credits_other")) {
                ForEach([AudioTagFieldKey.composer, .lyricist, .comment, .copyright], id: \.self) { key in field(key) }
                ratingRow
            }
            Section(L("group_replay_gain")) {
                ForEach(AudioTagFieldKey.replayGain, id: \.self) { key in field(key) }
            }
            Section(L("group_custom_tags")) {
                ForEach($model.edited.customFields) { $field in
                    HStack {
                        Text(field.key).font(.caption.monospaced()).foregroundStyle(.secondary).frame(minWidth: 80, alignment: .leading)
                        TextField(L("label_custom_tag_value"), text: $field.value, axis: .vertical)
                    }
                }
                .onDelete { idx in model.edited.customFields.remove(atOffsets: idx) }
                Button { newCustomKey = ""; newCustomValue = ""; showAddCustom = true } label: {
                    Label(L("action_add_custom_tag"), systemImage: "plus")
                }
            }
            fileInfoSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var lyricsPreview: String {
        let l = model.edited.lyrics ?? ""
        return l.isEmpty ? L("lyrics_empty") : l
    }

    private func field(_ key: AudioTagFieldKey) -> some View {
        let changed = (key.value(in: model.original) ?? "") != (key.value(in: model.edited) ?? "")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(L(key.labelKey)).font(.caption).foregroundStyle(.secondary)
                if changed { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            }
            TextField(L(key.labelKey), text: model.binding(key), axis: .vertical)
                .keyboardType(key == .trackNumber || key == .discNumber ? .numbersAndPunctuation : .default)
        }
    }

    private var ratingRow: some View {
        HStack {
            Text(L("label_rating"))
            Spacer()
            ForEach(1...5, id: \.self) { star in
                Image(systemName: (model.edited.rating ?? 0) >= star ? "star.fill" : "star")
                    .foregroundStyle(.yellow)
                    .onTapGesture {
                        model.edited.rating = model.edited.rating == star ? nil : star
                    }
            }
        }
    }

    private var coverSection: some View {
        Section(L("label_cover")) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let data = model.coverData, let img = UIImage(data: data) {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemFill))
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(L("ios_cover_from_photos"), systemImage: "photo.on.rectangle")
                    }
                    Button { showImageImporter = true } label: { Label(L("ios_cover_from_files"), systemImage: "folder") }
                    Button(role: .destructive) { model.removeCover() } label: { Label(L("label_remove_cover"), systemImage: "trash") }
                        .disabled(model.coverData == nil)
                    Button {
                        if let url = model.coverFileURL() { share = ShareItems(items: [url]) }
                    } label: { Label(L("label_save_cover"), systemImage: "square.and.arrow.down") }
                        .disabled(model.coverData == nil)
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
            .padding(.vertical, 4)
            if let data = model.coverData, let img = UIImage(data: data) {
                Text("\(Int(img.size.width * img.scale))×\(Int(img.size.height * img.scale)) · \(ImageMime.detect(data)) · \(Format.fileSize(Int64(data.count)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var fileInfoSection: some View {
        Section(L("group_track_details")) {
            InfoRow(label: L("label_file_path"), value: model.song?.relativePath ?? model.target?.fileName ?? "")
            if let song = model.song {
                InfoRow(label: L("label_file_size"), value: Format.fileSize(song.fileSize))
                InfoRow(label: L("label_date_modified"), value: Format.date(song.fileLastModified))
            }
            InfoRow(label: L("label_extension"), value: ((model.target?.fileName ?? "") as NSString).pathExtension.uppercased())
            InfoRow(label: L("label_duration"), value: Format.duration(ms: model.original.durationMilliseconds))
            InfoRow(label: L("label_bitrate"), value: "\(model.original.bitrate) kbps")
            InfoRow(label: L("label_sample_rate"), value: "\(model.original.sampleRate) Hz")
            InfoRow(label: L("label_channels"), value: "\(model.original.channels)")
        }
    }

    private func addCustomTag() {
        let key = newCustomKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty, !AudioTagKeys.isReserved(key), !model.edited.customFields.contains(where: { $0.key == key }) else {
            model.message = BannerMessage(text: L("custom_tag_key_invalid"), isError: true)
            return
        }
        model.edited.customFields.append(CustomTagField(key: key, value: newCustomValue))
        model.edited.customFields.sort { $0.key < $1.key }
    }
}

/// Plain lyrics text editor with import/export (Android lyrics editor, without plugin search).
struct LyricsEditorView: View {
    @ObservedObject var model: SongEditorModel
    @State private var showImporter = false
    @State private var share: ShareItems?

    var body: some View {
        TextEditor(text: Binding(get: { model.edited.lyrics ?? "" }, set: { model.edited.lyrics = $0.isEmpty ? nil : $0 }))
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 8)
            .navigationTitle(L("label_lyrics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button { showImporter = true } label: { Label(L("action_import_lyrics"), systemImage: "square.and.arrow.down") }
                        Button {
                            if let url = model.lyricsFileURL() { share = ShareItems(items: [url]) }
                        } label: { Label(L("action_export_lyrics"), systemImage: "square.and.arrow.up") }
                        Button {
                            UIPasteboard.general.string = model.edited.lyrics ?? ""
                            model.message = BannerMessage(text: L("msg_copied_to_clipboard"))
                        } label: { Label(L("action_copy_lyrics"), systemImage: "doc.on.doc") }
                        Button(role: .destructive) { model.edited.lyrics = nil } label: { Label(L("ios_clear_lyrics"), systemImage: "trash") }
                        Divider()
                        ForEach(LyricsHookRegistry.shared.actions) { action in
                            Button { Task { await action.run(model) } } label: { Label(action.title, systemImage: action.systemImage) }
                                .disabled(!action.isAvailable)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button(L("source_config_save")) { Task { await model.save() } }.disabled(!model.hasChanges)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, UTType(filenameExtension: "lrc") ?? .plainText, UTType(filenameExtension: "ttml") ?? .xml, .xml]) { result in
                if case .success(let url) = result {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
                        model.edited.lyrics = text
                        model.message = BannerMessage(text: L("msg_import_lyrics_success"))
                    } else {
                        model.message = BannerMessage(text: L("msg_import_lyrics_failed"), isError: true)
                    }
                }
            }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
            .banner($model.message)
    }
}
