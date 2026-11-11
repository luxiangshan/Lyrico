package com.lonx.lyrico.remote.integration

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import com.lonx.lyrico.remote.RemoteType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class RemoteEditorStep { FORM, BROWSE }

data class RemoteLocationUiState(
    val loaded: Boolean = false,
    val type: RemoteType = RemoteType.WEBDAV,
    val configId: String = "",
    val isEditing: Boolean = false,
    val name: String = "",
    val url: String = "",
    val share: String = "",
    val username: String = "",
    /** Typed password; blank while editing means "unchanged". */
    val password: String = "",
    val domain: String = "",
    val hasStoredSecret: Boolean = false,
    val step: RemoteEditorStep = RemoteEditorStep.FORM,
    val busy: Boolean = false,
    val error: String? = null,
    // folder browser
    val browsePath: String = "/",
    val browseEntries: List<RemoteEntry> = emptyList(),
    val browseLoading: Boolean = false,
    val selectedFolders: Set<String> = emptySet(),
    // 115 QR login
    val qrContent: String? = null,
    val qrState: QrLoginState? = null,
    /** Cookie obtained from a fresh QR login (replaces the stored one on save). */
    val newCookie: String? = null,
    val saved: Boolean = false,
)

class RemoteLocationViewModel(
    private val service: RemoteLocationService,
    private val qrBridge: Cloud115QrBridge,
) : ViewModel() {

    private val _uiState = MutableStateFlow(RemoteLocationUiState())
    val uiState: StateFlow<RemoteLocationUiState> = _uiState.asStateFlow()

    private var storage: RemoteStorage? = null
    private var qrJob: Job? = null

    fun load(type: RemoteType, configId: String) {
        if (_uiState.value.loaded) return
        viewModelScope.launch {
            val existing = configId.takeIf { it.isNotBlank() && it != "new" }?.let { service.configRepository.get(it) }
            if (existing != null) {
                val stored = service.configRepository.getWithSecret(existing.id)?.secret.orEmpty()
                _uiState.value = RemoteLocationUiState(
                    loaded = true,
                    type = existing.type,
                    configId = existing.id,
                    isEditing = true,
                    name = existing.displayName,
                    url = existing.baseUrl,
                    share = existing.share,
                    username = existing.username,
                    domain = existing.domain,
                    hasStoredSecret = stored.isNotEmpty(),
                    selectedFolders = existing.folders.map(RemoteUri::normalizePath).toSet(),
                )
            } else {
                _uiState.value = RemoteLocationUiState(
                    loaded = true,
                    type = type,
                    configId = RemoteConfigRepository.newId(),
                    name = RemoteFolderInfo.badgeOf(type),
                )
                if (type == RemoteType.CLOUD115) startQrLogin()
            }
        }
    }

    fun onNameChange(value: String) = _uiState.update { it.copy(name = value, error = null) }
    fun onUrlChange(value: String) = _uiState.update { it.copy(url = value, error = null) }
    fun onShareChange(value: String) = _uiState.update { it.copy(share = value, error = null) }
    fun onUsernameChange(value: String) = _uiState.update { it.copy(username = value, error = null) }
    fun onPasswordChange(value: String) = _uiState.update { it.copy(password = value, error = null) }
    fun onDomainChange(value: String) = _uiState.update { it.copy(domain = value, error = null) }

    /** Validates the form, tests the connection and opens the folder browser. */
    fun connect(missingFieldMessage: String) {
        val state = _uiState.value
        if (state.busy) return
        if (!isFormComplete(state)) {
            _uiState.update { it.copy(error = missingFieldMessage) }
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(busy = true, error = null) }
            try {
                closeStorage()
                val config = service.resolveForConnect(buildConfig(state), newSecretOf(state))
                val connected = service.connect(config)
                storage = connected
                _uiState.update {
                    it.copy(busy = false, step = RemoteEditorStep.BROWSE)
                }
                browse("/")
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                _uiState.update { it.copy(busy = false, error = e.message ?: e::class.java.simpleName) }
            }
        }
    }

    fun backToForm() {
        _uiState.update { it.copy(step = RemoteEditorStep.FORM, error = null) }
    }

    fun browse(path: String) {
        val current = storage ?: return
        viewModelScope.launch {
            _uiState.update { it.copy(browseLoading = true, error = null) }
            try {
                val entries = service.listFolders(current, RemoteUri.normalizePath(path))
                _uiState.update {
                    it.copy(browsePath = RemoteUri.normalizePath(path), browseEntries = entries, browseLoading = false)
                }
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                _uiState.update { it.copy(browseLoading = false, error = e.message ?: e::class.java.simpleName) }
            }
        }
    }

    fun browseUp() {
        val path = _uiState.value.browsePath
        if (path != "/") browse(RemoteUri.parentPath(path))
    }

    fun toggleFolder(path: String) {
        val normalized = RemoteUri.normalizePath(path)
        _uiState.update {
            val selected = it.selectedFolders.toMutableSet()
            if (!selected.add(normalized)) selected.remove(normalized)
            it.copy(selectedFolders = selected, error = null)
        }
    }

    /** Saves the location with the selected folders (re-tests the connection first) and queues a scan. */
    fun save(noFolderMessage: String) {
        val state = _uiState.value
        if (state.busy) return
        if (state.selectedFolders.isEmpty()) {
            _uiState.update { it.copy(error = noFolderMessage) }
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(busy = true, error = null) }
            try {
                val config = buildConfig(state).copy(folders = state.selectedFolders.sorted())
                val newSecret = newSecretOf(state)
                // Test connection on save, with exactly the settings that will be stored.
                val tested = service.connect(service.resolveForConnect(config, newSecret))
                withContext(Dispatchers.IO) { runCatching { tested.close() } }
                service.save(config, newSecret)
                _uiState.update { it.copy(busy = false, saved = true) }
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                _uiState.update { it.copy(busy = false, error = e.message ?: e::class.java.simpleName) }
            }
        }
    }

    // ---------------- 115 QR login ----------------

    fun startQrLogin() {
        qrJob?.cancel()
        qrJob = viewModelScope.launch {
            _uiState.update { it.copy(qrContent = null, qrState = null, error = null) }
            try {
                val content = withContext(Dispatchers.IO) { qrBridge.start() }
                _uiState.update { it.copy(qrContent = content, qrState = QrLoginState.WAITING) }
                while (isActive) {
                    val status = withContext(Dispatchers.IO) { qrBridge.poll() }
                    _uiState.update { it.copy(qrState = status) }
                    when (status) {
                        QrLoginState.CONFIRMED -> {
                            val cookie = withContext(Dispatchers.IO) { qrBridge.finish() }
                            _uiState.update { it.copy(newCookie = cookie) }
                            connect(missingFieldMessage = "")
                            return@launch
                        }
                        QrLoginState.EXPIRED, QrLoginState.CANCELLED -> return@launch
                        else -> delay(QR_POLL_GAP_MS)
                    }
                }
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                _uiState.update { it.copy(error = e.message ?: e::class.java.simpleName) }
            }
        }
    }

    // ---------------------------------------------------------------------------------------------

    private fun isFormComplete(state: RemoteLocationUiState): Boolean = when (state.type) {
        RemoteType.WEBDAV, RemoteType.OPENLIST -> state.url.isNotBlank()
        RemoteType.SMB -> state.url.isNotBlank() && state.share.isNotBlank()
        RemoteType.CLOUD115 -> state.newCookie != null || state.hasStoredSecret
    }

    /** null = keep the stored secret. */
    private fun newSecretOf(state: RemoteLocationUiState): String? = when (state.type) {
        RemoteType.CLOUD115 -> state.newCookie
        else -> if (state.isEditing && state.password.isEmpty()) null else state.password
    }

    private fun buildConfig(state: RemoteLocationUiState): RemoteConfig = RemoteConfig(
        id = state.configId,
        type = state.type,
        displayName = state.name.trim().ifBlank { RemoteFolderInfo.badgeOf(state.type) },
        baseUrl = normalizeUrl(state.type, state.url.trim()),
        share = state.share.trim().trim('/', '\\'),
        username = state.username.trim(),
        secret = "",
        domain = state.domain.trim(),
        folders = state.selectedFolders.sorted().ifEmpty { listOf("/") },
    )

    private fun normalizeUrl(type: RemoteType, url: String): String = when (type) {
        RemoteType.WEBDAV, RemoteType.OPENLIST ->
            if (url.isNotEmpty() && !url.contains("://")) "http://$url".trimEnd('/') else url.trimEnd('/')
        RemoteType.SMB -> url.removePrefix("smb://").removePrefix("\\\\").trimEnd('/', '\\')
        RemoteType.CLOUD115 -> url
    }

    private fun closeStorage() {
        val previous = storage
        storage = null
        if (previous != null) {
            Thread { runCatching { previous.close() } }.start()
        }
    }

    override fun onCleared() {
        qrJob?.cancel()
        closeStorage()
        super.onCleared()
    }

    private companion object {
        const val QR_POLL_GAP_MS = 1_000L
    }
}
