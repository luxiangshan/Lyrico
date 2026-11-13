import GRDB
import SwiftUI

struct ArtistsView: View {
    @StateObject private var model = LibraryIndexModel()
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List(model.artists) { artist in
            NavigationLink(value: Route.artist(artist.name)) {
                HStack(spacing: 12) {
                    CoverThumbnail(song: artist.sample, size: 44)
                        .clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(artist.name).lineLimit(1)
                        Text(L("album_song_count", artist.albums.count, artist.songCount)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if model.artists.isEmpty { Text(L("empty_artists_title")).foregroundStyle(.secondary) } }
        .searchable(text: $model.query)
        .navigationTitle(L("artist_list_title", model.artists.count))
        .toolbar {
            Menu {
                Picker(L("cd_sort"), selection: $settings.artistSortBy) {
                    ForEach(ArtistSortBy.allCases) { Text(L($0.labelKey)).tag($0.rawValue) }
                }
                Picker(L("cd_sort"), selection: $settings.artistSortAscending) {
                    Text(L("sort_ascending")).tag(true)
                    Text(L("sort_descending")).tag(false)
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
        }
        .onChange(of: settings.artistSortBy) { _ in model.rebuild() }
        .onChange(of: settings.artistSortAscending) { _ in model.rebuild() }
    }
}

struct AlbumsView: View {
    @StateObject private var model = LibraryIndexModel()
    @EnvironmentObject private var settings: AppSettings
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.albums) { album in
                    NavigationLink(value: Route.album(album.name)) {
                        VStack(alignment: .leading, spacing: 6) {
                            GeometryReader { geo in
                                CoverThumbnail(song: album.sample, size: geo.size.width)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(album.albumArtist.isEmpty ? L("unknown_artist") : album.albumArtist)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay { if model.albums.isEmpty { Text(L("empty_albums_title")).foregroundStyle(.secondary) } }
        .searchable(text: $model.query)
        .navigationTitle(L("album_list_title", model.albums.count))
        .toolbar {
            Menu {
                Picker(L("cd_sort"), selection: $settings.albumSortBy) {
                    ForEach(AlbumSortBy.allCases) { Text(L($0.labelKey)).tag($0.rawValue) }
                }
                Picker(L("cd_sort"), selection: $settings.albumSortAscending) {
                    Text(L("sort_ascending")).tag(true)
                    Text(L("sort_descending")).tag(false)
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
        }
        .onChange(of: settings.albumSortBy) { _ in model.rebuild() }
        .onChange(of: settings.albumSortAscending) { _ in model.rebuild() }
    }
}

/// Folder browsing: library folders at the root, then sub-directories + songs.
struct FolderBrowserRootView: View {
    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        List {
            ForEach(library.folders.filter { !$0.isIgnored }) { folder in
                NavigationLink(value: Route.folder(folder.id ?? 0, "/")) {
                    FolderRowLabel(folder: folder)
                }
            }
        }
        .navigationTitle(L("folder_tab_folders"))
        .toolbar {
            NavigationLink(value: Route.folderManager) { Image(systemName: "folder.badge.gearshape") }
        }
    }
}

struct FolderRowLabel: View {
    let folder: FolderRecord

    var icon: String {
        switch folder.kind {
        case .documents: return "iphone"
        case .local: return "folder"
        case .remote: return "externaldrive.connected.to.line.below"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.kind == .documents ? L("ios_documents_folder") : folder.displayName).lineLimit(1)
                Text(L("song_count", folder.songCount)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Sub-directories + songs directly inside `directory`.
struct FolderContentView: View {
    let folderId: Int64
    let directory: String
    @State private var subdirs: [SubDir] = []

    struct SubDir: Hashable { let name: String; let count: Int }

    var body: some View {
        SongListView(scope: .folder(folderId, directory))
            .safeAreaInset(edge: .top) {
                if !subdirs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(subdirs, id: \.name) { d in
                                NavigationLink(value: Route.folder(folderId, joinPath(directory, d.name))) {
                                    Label("\(d.name) (\(d.count))", systemImage: "folder")
                                        .font(.footnote)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color(.secondarySystemBackground), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                    .background(.bar)
                }
            }
            .task { await loadSubdirs() }
    }

    private func loadSubdirs() async {
        let prefix = directory == "/" ? "/" : directory + "/"
        let paths: [String] = (try? await AppDatabase.shared.pool.read { db in
            try String.fetchAll(db, sql: "SELECT relativePath FROM songs WHERE folderId = ? AND relativePath LIKE ? ESCAPE '\\'",
                                arguments: [folderId, SongListModel.escapeLike(prefix) + "%"])
        }) ?? []
        var counts: [String: Int] = [:]
        for p in paths {
            let rest = String(p.dropFirst(prefix.count))
            if let slash = rest.firstIndex(of: "/") {
                counts[String(rest[..<slash]), default: 0] += 1
            }
        }
        subdirs = counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { SubDir(name: $0.key, count: $0.value) }
    }
}
