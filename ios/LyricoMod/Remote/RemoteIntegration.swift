// Wiring point for the optional RemoteStorage package (ios/Packages/RemoteStorage, branch ios-remote).
// generate-project.sh links the package automatically when it exists; then fill in the adapter below
// so that RemoteStorageRegistry.shared.factory creates package clients for RemoteLocation.
import Foundation
#if canImport(RemoteStorage)
import RemoteStorage
#endif

enum RemoteIntegration {
    static var isPackageLinked: Bool {
        #if canImport(RemoteStorage)
        return true
        #else
        return false
        #endif
    }

    /// Called once at app start (LyricoModApp.init).
    static func register() {
        #if canImport(RemoteStorage)
        // INTEGRATION: set RemoteStorageRegistry.shared.factory = { config in <PackageClientAdapter>(config) }
        // where the adapter conforms to RemoteStorageClient (see RemoteStorageClient.swift).
        #endif
    }
}
