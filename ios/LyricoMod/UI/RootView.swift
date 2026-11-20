import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case songs, artists, albums, folders, folderManager, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: return L("library_tab_songs")
        case .artists: return L("library_tab_artists")
        case .albums: return L("library_tab_albums")
        case .folders: return L("folder_tab_folders")
        case .folderManager: return L("folder_manager_title")
        case .settings: return L("settings_title")
        }
    }

    var icon: String {
        switch self {
        case .songs: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .folders: return "folder"
        case .folderManager: return "folder.badge.gearshape"
        case .settings: return "gearshape"
        }
    }
}

/// iPad (regular width): NavigationSplitView with a sidebar. iPhone: TabView.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var router: AppRouter
    @State private var selection: SidebarItem? = .songs
    @State private var tab: SidebarItem = .songs

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(SidebarItem.allCases, selection: $selection) { item in
                        NavigationLink(value: item) { Label(item.title, systemImage: item.icon) }
                    }
                    .navigationTitle("Lyrico Mod")
                } detail: {
                    let item = selection ?? .songs
                    NavigationStack {
                        RootContent(item: item).withRoutes()
                    }
                    .id(item)
                }
            } else {
                TabView(selection: $tab) {
                    ForEach([SidebarItem.songs, .artists, .albums, .folders, .settings]) { item in
                        NavigationStack {
                            RootContent(item: item).withRoutes()
                        }
                        .tabItem { Label(item.title, systemImage: item.icon) }
                        .tag(item)
                    }
                }
            }
        }
        .sheet(item: $router.externalFile) { file in
            NavigationStack { ExternalFileEditorView(url: file.url) }
        }
    }
}

struct RootContent: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .songs: SongListView(scope: .all)
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .folders: FolderBrowserRootView()
        case .folderManager: FolderManagerView()
        case .settings: SettingsView()
        }
    }
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .song(let id): SongEditorView(songId: id)
            case .artist(let name): SongListView(scope: .artist(name))
            case .album(let name): SongListView(scope: .album(name))
            case .folder(let id, let dir): FolderContentView(folderId: id, directory: dir)
            case .folderManager: FolderManagerView()
            }
        }
    }
}
