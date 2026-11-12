import SwiftUI

/// Song list with search, sort, multi-select and batch actions (Android SongsPage + selection bar).
struct SongListView: View {
    let scope: SongScope
    @StateObject private var model: SongListModel
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var settings: AppSettings
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int64>()
    @State private var share: ShareItems?
    @State private var preparingShare = false
    @State private var confirmDelete: [SongRecord]?
    @State private var batchSheet: BatchSheet?
    @State private var renameTarget: SongRecord?
    @State private var renameText = ""
    @State private var banner: BannerMessage?
    @State private var showFolderPicker = false

    enum BatchSheet: Identifiable {
        case edit([Int64]), rename([Int64]), action(BatchActionDescriptor, [Int64])
        var id: String {
            switch self {
            case .edit(let ids): return "e\(ids.hashValue)"
            case .rename(let ids): return "r\(ids.hashValue)"
            case .action(let d, let ids): return "a\(d.id)\(ids.hashValue)"
            }
        }
    }

    init(scope: SongScope) {
        self.scope = scope
        _model = StateObject(wrappedValue: SongListModel(scope: scope))
    }

    private var title: String {
        switch scope {
        case .all: return L("song_list_title")
        case .artist(let n): return n
        case .album(let n): return n.isEmpty ? L("unknown_album") : n
        case .folder(_, let dir): return dir == "/" ? L("folder_tab_folders") : (dir as NSString).lastPathComponent
        case .ids: return L("song_list_title")
        }
    }

    private var isSelecting: Bool { editMode.isEditing }
    private var selectedSongs: [SongRecord] { model.songs.filter { selection.contains($0.id ?? -1) } }

    var body: some View {
        list
            .navigationTitle(isSelecting ? L("selection_mode_selected_count", selection.count) : title)
            .navigationBarTitleDisplayMode(scope == .all ? .large : .inline)
            .searchable(text: $model.query, prompt: L("local_search_hint"))
            .environment(\.editMode, $editMode)
            .toolbar { toolbar }
            .refreshable { library.startScan() }
            .safeAreaInset(edge: .top) { scanBanner }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
            .sheet(item: $batchSheet) { sheet in
                NavigationStack {
                    switch sheet {
                    case .edit(let ids): BatchEditView(songIds: ids)
                    case .rename(let ids): BatchRenameView(songIds: ids)
                    case .action(let d, let ids): BatchActionRunnerView(descriptor: d, songIds: ids)
                    }
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in library.addLocalFolder(url) }
            }
            .confirmationDialog(L("dialog_delete_file_title"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button(L("action_delete"), role: .destructive) {
                    let songs = confirmDelete ?? []
                    confirmDelete = nil
                    Task { await delete(songs) }
                }
            } message: {
                if let songs = confirmDelete {
                    Text(songs.count == 1 ? L("dialog_delete_file_content", songs[0].fileName) : L("dialog_batch_delete_content", songs.count))
                }
            }
            .alert(L("dialog_rename_title"), isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField(L("label_new_name"), text: $renameText)
                Button(L("cancel"), role: .cancel) { renameTarget = nil }
                Button(L("confirm")) {
                    if let song = renameTarget {
                        let name = renameText
                        Task {
                            do { try await SongFileService.rename(song, to: name) } catch { banner = BannerMessage(text: error.localizedDescription, isError: true) }
                        }
                    }
                    renameTarget = nil
                }
            }
            .banner($banner)
    }

    @ViewBuilder private var list: some View {
        if model.loaded && model.songs.isEmpty && model.query.isEmpty && scope == .all {
            emptyLibrary
        } else {
            List(selection: $selection) {
                ForEach(model.songs, id: \.id) { song in
                    row(song).tag(song.id ?? -1)
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.loaded && model.songs.isEmpty {
                    Text(L("search_empty")).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func row(_ song: SongRecord) -> some View {
        let content = SongRow(song: song)
        Group {
            if isSelecting {
                content
            } else {
                NavigationLink(value: Route.song(song.id ?? -1)) { content }
            }
        }
        .contextMenu {
            Button { renameText = (song.fileName as NSString).deletingPathExtension; renameTarget = song } label: { Label(L("menu_action_rename"), systemImage: "pencil") }
            Button { Task { await prepareShare([song]) } } label: { Label(L("menu_action_share"), systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { confirmDelete = [song] } label: { Label(L("menu_action_delete"), systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirmDelete = [song] } label: { Label(L("action_delete"), systemImage: "trash") }
            Button { Task { await prepareShare([song]) } } label: { Label(L("action_share"), systemImage: "square.and.arrow.up") }.tint(.blue)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house").font(.system(size: 52)).foregroundStyle(.secondary)
            Text(L("song_list_empty_title")).font(.title3.bold())
            Text(L("song_list_empty_desc")).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(L("ios_documents_hint")).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { showFolderPicker = true } label: { Label(L("action_add_folder"), systemImage: "folder.badge.plus") }
                .buttonStyle(.borderedProminent)
            Button { library.startScan() } label: { Label(L("action_refresh_folder"), systemImage: "arrow.clockwise") }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var scanBanner: some View {
        if library.scan.isRunning || library.scan.phase == .finished {
            HStack(spacing: 8) {
                if library.scan.isRunning { ProgressView().controlSize(.small) }
                Text(library.scan.text).font(.footnote)
                if !library.scan.folderName.isEmpty && library.scan.isRunning {
                    Text(library.scan.folderName).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelecting {
                Button(selection.count == model.songs.count ? L("action_deselect_all") : L("action_select_all")) {
                    if selection.count == model.songs.count { selection.removeAll() } else { selection = Set(model.songs.compactMap(\.id)) }
                }
                Button(L("confirm")) { withAnimation { editMode = .inactive; selection.removeAll() } }
            } else {
                sortMenu
                Button { withAnimation { editMode = .active } } label: { Image(systemName: "checkmark.circle") }
                    .accessibilityLabel(L("swipe_selection_enter_selection"))
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if isSelecting {
                let ids = selectedSongs.compactMap(\.id)
                Button { batchSheet = .edit(ids) } label: { Label(L("common_edit"), systemImage: "square.and.pencil") }.disabled(ids.isEmpty)
                Spacer()
                Button { batchSheet = .rename(ids) } label: { Label(L("action_batch_rename"), systemImage: "character.cursor.ibeam") }.disabled(ids.isEmpty)
                Spacer()
                Button { Task { await prepareShare(selectedSongs) } } label: {
                    if preparingShare { ProgressView() } else { Label(L("action_share"), systemImage: "square.and.arrow.up") }
                }.disabled(ids.isEmpty || preparingShare)
                Spacer()
                Button(role: .destructive) { confirmDelete = selectedSongs } label: { Label(L("action_delete"), systemImage: "trash") }.disabled(ids.isEmpty)
                Spacer()
                Menu {
                    ForEach(BatchActionRegistry.shared.actions) { action in
                        Button { batchSheet = .action(action, ids) } label: { Label(action.title, systemImage: action.systemImage) }
                            .disabled(!action.isAvailable)
                    }
                } label: { Label(L("cd_more_actions"), systemImage: "ellipsis.circle") }.disabled(ids.isEmpty)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(L("cd_sort"), selection: $settings.songSortBy) {
                ForEach(SongSortBy.allCases) { Text(L($0.labelKey)).tag($0.rawValue) }
            }
            Picker(L("cd_sort"), selection: $settings.songSortAscending) {
                Text(L("sort_ascending")).tag(true)
                Text(L("sort_descending")).tag(false)
            }
        } label: { Image(systemName: "arrow.up.arrow.down") }
            .onChange(of: settings.songSortBy) { _ in model.restart() }
            .onChange(of: settings.songSortAscending) { _ in model.restart() }
    }

    private func prepareShare(_ songs: [SongRecord]) async {
        preparingShare = true
        let urls = await SongFileService.shareableURLs(songs)
        preparingShare = false
        if urls.isEmpty { banner = BannerMessage(text: L("unknown_error_simple"), isError: true) } else { share = ShareItems(items: urls) }
    }

    private func delete(_ songs: [SongRecord]) async {
        var failed = 0
        for s in songs {
            do { try await SongFileService.delete(s) } catch { failed += 1 }
        }
        selection.removeAll()
        editMode = .inactive
        if failed > 0 { banner = BannerMessage(text: L("ios_delete_failed_count", failed), isError: true) }
    }
}

struct SongRow: View {
    let song: SongRecord

    var body: some View {
        HStack(spacing: 12) {
            CoverThumbnail(song: song, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayTitle).font(.body).lineLimit(1)
                Text("\(song.displayArtist) · \(song.displayAlbum)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.duration(ms: song.durationMilliseconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text((song.fileExtension ?? "").uppercased()).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
