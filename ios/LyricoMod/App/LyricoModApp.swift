import SwiftUI

@main
struct LyricoModApp: App {
    @StateObject private var library = LibraryManager.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var router = AppRouter()

    init() {
        RemoteIntegration.register()
        PluginIntegration.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(router)
                .onOpenURL { url in router.openExternalFile(url) }
                .task {
                    if settings.scanOnLaunch { library.startScan() }
                }
        }
    }
}

/// Navigation destinations shared by every stack.
enum Route: Hashable {
    case song(Int64)
    case artist(String)
    case album(String)
    case folder(Int64, String)
    case folderManager
}

/// Holds cross-screen navigation requests (e.g. files opened from the Files app).
@MainActor
final class AppRouter: ObservableObject {
    @Published var externalFile: ExternalFile?

    struct ExternalFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    func openExternalFile(_ url: URL) {
        guard url.isFileURL else { return }
        externalFile = ExternalFile(url: url)
    }
}
