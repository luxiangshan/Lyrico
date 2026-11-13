import SwiftUI

/// Folder management (Android FolderManagerScreen): Documents + picked local folders now,
/// remote locations once the RemoteStorage package is linked.
struct FolderManagerView: View {
    @EnvironmentObject private var library: LibraryManager
    @State private var showPicker = false
    @State private var confirmRemove: FolderRecord?
    @State private var showRemoteInfo = false
    @State private var remoteEditor: RemoteEditorTarget?

    struct RemoteEditorTarget: Identifiable {
        let id = UUID()
        let kind: RemoteKind
        let existing: RemoteLocation?
    }

    var body: some View {
        List {
            Section(footer: Text(L("folder_manage_hint") + "\n" + L("ios_documents_hint"))) {
                ForEach(library.folders) { folder in
                    HStack {
                        FolderRowLabel(folder: folder)
                            .opacity(folder.isIgnored ? 0.5 : 1)
                        Spacer()
                        if let last = folder.lastScanned {
                            Text(last, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .contextMenu { menu(folder) }
                    .swipeActions {
                        if folder.kind != .documents {
                            Button(role: .destructive) { confirmRemove = folder } label: { Label(L("folder_action_remove"), systemImage: "trash") }
                        }
                        Button { library.startScan(folderIds: [folder.id ?? 0]) } label: { Label(L("ios_rescan"), systemImage: "arrow.clockwise") }.tint(.blue)
                    }
                }
            }
            if !library.scan.errors.isEmpty {
                Section(L("ios_scan_errors")) {
                    ForEach(library.scan.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle(L("folder_manager_title"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if library.scan.isRunning { ProgressView() }
                Menu {
                    Button { showPicker = true } label: { Label(L("ios_add_local_folder"), systemImage: "folder.badge.plus") }
                    Section(L("ios_remote_locations")) {
                        ForEach(RemoteKind.allCases) { kind in
                            Button {
                                if RemoteStorageRegistry.shared.isAvailable { remoteEditor = RemoteEditorTarget(kind: kind, existing: nil) } else { showRemoteInfo = true }
                            } label: { Label(kind == .cloud115 ? L("remote_type_115") : kind.label, systemImage: kind == .smb ? "server.rack" : (kind == .cloud115 ? "icloud" : "network")) }
                        }
                    }
                } label: { Image(systemName: "plus") }
                Button { library.startScan() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(library.scan.isRunning)
            }
        }
        .sheet(isPresented: $showPicker) {
            FolderPicker { url in library.addLocalFolder(url) }
        }
        .sheet(item: $remoteEditor) { target in
            NavigationStack {
                if let existing = target.existing {
                    RemoteLocationEditorView(existing: existing)
                } else {
                    RemoteLocationEditorView(kind: target.kind)
                }
            }
            .environmentObject(library)
        }
        .alert(L("ios_remote_locations"), isPresented: $showRemoteInfo) {
            Button(L("confirm"), role: .cancel) {}
        } message: { Text(L("ios_remote_unavailable")) }
        .confirmationDialog(L("dialog_remove_folder_title"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button(L("folder_action_remove"), role: .destructive) {
                if let f = confirmRemove { library.removeFolder(f) }
                confirmRemove = nil
            }
        } message: { Text(L("dialog_remove_folder_content_tip")) }
        .alert(L("unknown_error_simple"), isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button(L("confirm"), role: .cancel) {}
        } message: { Text(library.lastError ?? "") }
    }

    @ViewBuilder private func menu(_ folder: FolderRecord) -> some View {
        Button { library.startScan(folderIds: [folder.id ?? 0]) } label: { Label(L("ios_rescan"), systemImage: "arrow.clockwise") }
        Button { library.setIgnored(folder, !folder.isIgnored) } label: {
            Label(folder.isIgnored ? L("folder_action_show") : L("folder_action_hide"), systemImage: folder.isIgnored ? "eye" : "eye.slash")
        }
        if folder.kind == .remote, let locId = folder.sourceId, let loc = RemoteLocationStore.shared.config(id: locId) {
            Button { remoteEditor = RemoteEditorTarget(kind: loc.type, existing: loc) } label: { Label(L("remote_action_edit"), systemImage: "pencil") }
        }
        if folder.kind != .documents {
            Button(role: .destructive) { confirmRemove = folder } label: { Label(L("folder_action_remove"), systemImage: "trash") }
        }
    }
}
