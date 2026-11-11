package com.lonx.lyrico.remote.integration

import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteCredentialStore
import com.lonx.lyrico.remote.RemoteStorage
import com.lonx.lyrico.remote.RemoteType
import com.lonx.lyrico.remote.cloud115.Cloud115Storage
import com.lonx.lyrico.remote.smb.SmbStorage
import com.lonx.lyrico.remote.webdav.OpenListStorage
import com.lonx.lyrico.remote.webdav.WebDavStorage

/**
 * Creates the provider implementation for a [RemoteConfig]. Providers are constructed as
 * `XStorage(config: RemoteConfig, store: RemoteCredentialStore)` (WebDAV: `WebDavStorage(config)`).
 */
class RemoteStorageFactory(
    private val credentialStore: RemoteCredentialStore,
) {
    fun create(config: RemoteConfig): RemoteStorage = when (config.type) {
        // WebDavStorage(config, baseClient = …) takes no credential store (plain Basic/Digest auth, nothing to cache).
        RemoteType.WEBDAV -> WebDavStorage(config)
        RemoteType.OPENLIST -> OpenListStorage(config, credentialStore)
        RemoteType.SMB -> SmbStorage(config, credentialStore)
        RemoteType.CLOUD115 -> Cloud115Storage(config, credentialStore)
    }
}
