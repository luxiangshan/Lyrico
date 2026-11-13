import SwiftUI
#if canImport(LyricoPlugins)
import LyricoPlugins
#endif

/// Settings (Android SettingsScreen subset relevant on iOS).
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryManager
    @State private var cacheSize: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section(L("section_scan")) {
                NavigationLink(value: Route.folderManager) { Label(L("folder_manager"), systemImage: "folder.badge.gearshape") }
                Toggle(L("ignore_short_audio"), isOn: $settings.ignoreShortAudio)
                Toggle(L("ios_scan_on_launch"), isOn: $settings.scanOnLaunch)
                Button { library.startScan() } label: { Label(L("action_refresh_folder"), systemImage: "arrow.clockwise") }
                    .disabled(library.scan.isRunning)
            }
            #if canImport(LyricoPlugins)
            Section {
                NavigationLink {
                    PluginManagerView(manager: .shared)
                } label: { Label(L("plugin_manager_title"), systemImage: "puzzlepiece.extension") }
            }
            #endif
            Section(header: Text(L("section_text_processing")), footer: Text(L("artist_separator_hint"))) {
                HStack {
                    Text(L("ios_multi_value_separator"))
                    Spacer()
                    TextField("/", text: $settings.multiValueSeparator).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                }
                Toggle(L("artist_split_enabled"), isOn: $settings.artistSplitEnabled)
                HStack {
                    Text(L("artist_separator"))
                    Spacer()
                    TextField("/;、", text: $settings.artistSeparators).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                }
                HStack {
                    Text(L("rename_format"))
                    Spacer()
                    TextField("@1 - @2", text: $settings.renameFormat).multilineTextAlignment(.trailing).frame(maxWidth: 160)
                }
            }
            Section(L("section_appearance")) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: { Label(L("app_language"), systemImage: "globe") }
            }
            Section(L("section_other")) {
                HStack {
                    Text(L("cache_category_image"))
                    Spacer()
                    Text(Format.fileSize(cacheSize)).foregroundStyle(.secondary)
                }
                Stepper(value: $settings.coverCacheLimitMB, in: 32...1024, step: 32) {
                    Text(L("ios_cover_cache_limit", settings.coverCacheLimitMB))
                }
                Button(L("clear_cache")) {
                    CoverCache.shared.clear()
                    cacheSize = CoverCache.shared.diskSize()
                }
                Button(L("clear_songs"), role: .destructive) { confirmClear = true }
            }
            Section(L("about_title")) {
                InfoRow(label: L("about_app_version"), value: appVersion)
                InfoRow(label: "TagLib", value: TagLib.version)
                InfoRow(label: L("ios_integrations"), value: integrations)
                NavigationLink(L("title_opensource_licence")) { LicensesView() }
                Link(destination: URL(string: "https://github.com/luxiangshan/Lyrico")!) {
                    Label(L("about_project_url"), systemImage: "link")
                }
            }
        }
        .navigationTitle(L("settings_title"))
        .task { cacheSize = CoverCache.shared.diskSize() }
        .confirmationDialog(L("clear_songs"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("clear_songs"), role: .destructive) { library.clearLibrary() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var integrations: String {
        let remote = RemoteIntegration.isPackageLinked ? "RemoteStorage ✓" : "RemoteStorage –"
        let plugins = PluginIntegration.isPackageLinked ? "LyricoPlugins ✓" : "LyricoPlugins –"
        return remote + "  " + plugins
    }
}

struct LicensesView: View {
    struct Item: Identifiable { let name: String; let license: String; let url: String; var id: String { name } }
    private let items: [Item] = [
        Item(name: "Lyrico", license: "Apache License 2.0", url: "https://github.com/Replica0110/Lyrico"),
        Item(name: "TagLib", license: "LGPL 2.1 / MPL 1.1", url: "https://github.com/taglib/taglib"),
        Item(name: "utfcpp", license: "Boost Software License 1.0", url: "https://github.com/nemtrif/utfcpp"),
        Item(name: "GRDB.swift", license: "MIT License", url: "https://github.com/groue/GRDB.swift"),
    ]

    var body: some View {
        List(items) { item in
            Link(destination: URL(string: item.url)!) {
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(item.license).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L("title_opensource_licence"))
    }
}
