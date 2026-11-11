package com.lonx.lyrico.screens

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.lonx.lyrico.R
import com.lonx.lyrico.data.model.UiEngine
import com.lonx.lyrico.remote.RemoteType
import com.lonx.lyrico.remote.integration.QrCodeBitmap
import com.lonx.lyrico.remote.integration.QrLoginState
import com.lonx.lyrico.remote.integration.RemoteEditorStep
import com.lonx.lyrico.remote.integration.RemoteFolderInfo
import com.lonx.lyrico.remote.integration.RemoteLocationUiState
import com.lonx.lyrico.remote.integration.RemoteLocationViewModel
import com.lonx.lyrico.remote.integration.RemoteUri
import com.lonx.lyrico.ui.components.editor.rememberEditorTextFieldState
import com.lonx.lyrico.ui.components.icons.LucideIcons
import com.lonx.lyrico.ui.components.library.LibraryDetailPage
import com.lonx.lyrico.ui.components.salt.SaltIconButton
import com.lonx.lyrico.ui.theme.LocalUiEngine
import com.ramcosta.composedestinations.annotation.Destination
import com.ramcosta.composedestinations.annotation.RootGraph
import com.ramcosta.composedestinations.navigation.DestinationsNavigator
import org.koin.androidx.compose.koinViewModel
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.SmallTopAppBar
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.basic.TextField
import top.yukonga.miuix.kmp.theme.MiuixTheme

/**
 * Lyrico Mod: add / edit a remote location (WebDAV, OpenList, SMB, 115) and pick its folders.
 * [type] is a [RemoteType] name; [configId] is "new" when adding a new location.
 */
@Composable
@Destination<RootGraph>(route = "remote_location")
fun RemoteLocationScreen(
    type: String,
    configId: String,
    navigator: DestinationsNavigator
) {
    val viewModel: RemoteLocationViewModel = koinViewModel()
    val uiState by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    val salt = LocalUiEngine.current == UiEngine.SALT
    val scrollBehavior = MiuixScrollBehavior()

    LaunchedEffect(type, configId) {
        val remoteType = runCatching { RemoteType.valueOf(type) }.getOrDefault(RemoteType.WEBDAV)
        viewModel.load(remoteType, configId)
    }

    val savedText = stringResource(R.string.remote_saved)
    LaunchedEffect(uiState.saved) {
        if (uiState.saved) {
            Toast.makeText(context, savedText, Toast.LENGTH_SHORT).show()
            navigator.navigateUp()
        }
    }

    val typeLabel = when (uiState.type) {
        RemoteType.CLOUD115 -> stringResource(R.string.remote_type_115)
        else -> RemoteFolderInfo.badgeOf(uiState.type)
    }
    val title = stringResource(
        if (uiState.isEditing) R.string.remote_edit_title else R.string.remote_add_title,
        typeLabel
    )
    val missingFields = stringResource(R.string.remote_missing_fields)
    val noFolder = stringResource(R.string.remote_no_folder_selected)
    val inBrowser = uiState.step == RemoteEditorStep.BROWSE

    val onBack: () -> Unit = {
        if (inBrowser) viewModel.backToForm() else navigator.navigateUp()
    }
    BackHandler(enabled = inBrowser) { viewModel.backToForm() }

    val primaryAction: () -> Unit = {
        if (inBrowser) viewModel.save(noFolder) else viewModel.connect(missingFields)
    }
    val primaryIcon = if (inBrowser) LucideIcons.Check else LucideIcons.ArrowRight
    val primaryLabel = stringResource(if (inBrowser) R.string.remote_save else R.string.remote_connect)

    LibraryDetailPage(
        title = title,
        onBack = onBack,
        actions = {
            SaltIconButton(primaryIcon, primaryLabel, onClick = primaryAction)
        },
        miuixTopBar = {
            SmallTopAppBar(
                title = title,
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(imageVector = LucideIcons.ArrowLeft, contentDescription = stringResource(R.string.action_back))
                    }
                },
                actions = {
                    IconButton(onClick = primaryAction) {
                        Icon(imageVector = primaryIcon, contentDescription = primaryLabel)
                    }
                },
                scrollBehavior = scrollBehavior
            )
        }
    ) { paddingValues ->
        Column(
            modifier = (if (salt) Modifier else Modifier.nestedScroll(scrollBehavior.nestedScrollConnection))
                .fillMaxSize()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(com.lonx.lyrico.ui.components.scaffoldContentPadding(paddingValues, bottomExtra = 24.dp))
        ) {
            uiState.error?.let { error ->
                Text(
                    text = error,
                    color = MiuixTheme.colorScheme.error,
                    fontSize = MiuixTheme.textStyles.body2.fontSize,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                )
            }
            if (!uiState.loaded) return@Column
            if (inBrowser) {
                RemoteFolderBrowser(uiState, viewModel)
            } else {
                RemoteConnectionForm(uiState, viewModel, onConnect = { viewModel.connect(missingFields) })
            }
        }
    }
}

@Composable
private fun RemoteConnectionForm(
    state: RemoteLocationUiState,
    viewModel: RemoteLocationViewModel,
    onConnect: () -> Unit,
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Column(
            modifier = Modifier.padding(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            RemoteTextField(state.name, viewModel::onNameChange, stringResource(R.string.remote_field_name))
            when (state.type) {
                RemoteType.WEBDAV -> {
                    RemoteTextField(state.url, viewModel::onUrlChange, stringResource(R.string.remote_field_url_webdav),
                        keyboardType = KeyboardType.Uri)
                    RemoteTextField(state.username, viewModel::onUsernameChange, stringResource(R.string.remote_field_username))
                    RemotePasswordField(state, viewModel)
                }
                RemoteType.OPENLIST -> {
                    RemoteTextField(state.url, viewModel::onUrlChange, stringResource(R.string.remote_field_url_openlist),
                        keyboardType = KeyboardType.Uri)
                    RemoteTextField(state.username, viewModel::onUsernameChange, stringResource(R.string.remote_field_username_openlist))
                    RemotePasswordField(state, viewModel)
                }
                RemoteType.SMB -> {
                    RemoteTextField(state.url, viewModel::onUrlChange, stringResource(R.string.remote_field_host_smb),
                        keyboardType = KeyboardType.Uri)
                    RemoteTextField(state.share, viewModel::onShareChange, stringResource(R.string.remote_field_share))
                    RemoteTextField(state.username, viewModel::onUsernameChange, stringResource(R.string.remote_field_username))
                    RemotePasswordField(state, viewModel)
                    RemoteTextField(state.domain, viewModel::onDomainChange, stringResource(R.string.remote_field_domain))
                }
                RemoteType.CLOUD115 -> Cloud115QrPanel(state, viewModel)
            }
        }
    }

    if (state.type != RemoteType.CLOUD115 || state.hasStoredSecret || state.newCookie != null) {
        Spacer(Modifier.height(8.dp))
        TextButton(
            text = stringResource(
                when {
                    state.busy -> R.string.remote_connecting
                    state.type == RemoteType.CLOUD115 && state.newCookie == null -> R.string.remote_qr_use_saved
                    else -> R.string.remote_connect
                }
            ),
            onClick = onConnect,
            enabled = !state.busy,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
            colors = ButtonDefaults.textButtonColorsPrimary(),
        )
    }
}

@Composable
private fun Cloud115QrPanel(state: RemoteLocationUiState, viewModel: RemoteLocationViewModel) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (state.isEditing && state.hasStoredSecret && state.newCookie == null) {
            Text(
                text = stringResource(R.string.remote_qr_saved_hint),
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                fontSize = MiuixTheme.textStyles.body2.fontSize
            )
            Spacer(Modifier.height(8.dp))
        }
        Text(
            text = stringResource(R.string.remote_qr_hint),
            color = MiuixTheme.colorScheme.onBackground,
        )
        Spacer(Modifier.height(12.dp))
        val qrBitmap = remember(state.qrContent) {
            state.qrContent?.let { runCatching { QrCodeBitmap.encode(it).asImageBitmap() }.getOrNull() }
        }
        Box(
            modifier = Modifier
                .size(220.dp)
                .background(Color.White),
            contentAlignment = Alignment.Center
        ) {
            if (qrBitmap != null) {
                Image(bitmap = qrBitmap, contentDescription = null, modifier = Modifier.size(208.dp))
            } else if (state.qrContent == null && state.qrState == null && state.error == null) {
                androidx.compose.material3.CircularProgressIndicator(modifier = Modifier.size(32.dp))
            }
        }
        Spacer(Modifier.height(12.dp))
        val statusText = when (state.qrState) {
            QrLoginState.WAITING -> stringResource(R.string.remote_qr_waiting)
            QrLoginState.SCANNED -> stringResource(R.string.remote_qr_scanned)
            QrLoginState.CONFIRMED -> stringResource(R.string.remote_qr_confirmed)
            QrLoginState.EXPIRED -> stringResource(R.string.remote_qr_expired)
            QrLoginState.CANCELLED -> stringResource(R.string.remote_qr_cancelled)
            null -> null
        }
        statusText?.let {
            Text(
                text = it,
                fontWeight = FontWeight.Medium,
                color = if (state.qrState == QrLoginState.EXPIRED || state.qrState == QrLoginState.CANCELLED) {
                    MiuixTheme.colorScheme.error
                } else {
                    MiuixTheme.colorScheme.primary
                }
            )
        }
        Spacer(Modifier.height(8.dp))
        TextButton(
            text = stringResource(R.string.remote_qr_refresh),
            onClick = viewModel::startQrLogin,
            enabled = !state.busy,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun RemoteFolderBrowser(state: RemoteLocationUiState, viewModel: RemoteLocationViewModel) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = state.browsePath,
                fontWeight = FontWeight.Medium,
                color = MiuixTheme.colorScheme.onBackground
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = stringResource(R.string.remote_browse_selected, state.selectedFolders.size),
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                fontSize = MiuixTheme.textStyles.body2.fontSize
            )
            if (state.selectedFolders.isNotEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = state.selectedFolders.sorted().joinToString("\n"),
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                    fontSize = MiuixTheme.textStyles.footnote1.fontSize
                )
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(
                    text = stringResource(R.string.remote_browse_up),
                    onClick = viewModel::browseUp,
                    enabled = state.browsePath != "/" && !state.browseLoading,
                    modifier = Modifier.weight(1f),
                )
                val currentSelected = state.browsePath in state.selectedFolders
                TextButton(
                    text = stringResource(R.string.remote_browse_select_current) + if (currentSelected) " ✓" else "",
                    onClick = { viewModel.toggleFolder(state.browsePath) },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.textButtonColorsPrimary(),
                )
            }
        }
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Column(modifier = Modifier.padding(vertical = 4.dp)) {
            when {
                state.browseLoading -> Text(
                    text = stringResource(R.string.remote_browse_loading),
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                    modifier = Modifier.padding(16.dp)
                )
                state.browseEntries.isEmpty() -> Text(
                    text = stringResource(R.string.remote_browse_empty),
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                    modifier = Modifier.padding(16.dp)
                )
                else -> state.browseEntries.forEach { entry ->
                    val path = RemoteUri.normalizePath(entry.path)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { viewModel.browse(path) }
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        androidx.compose.material3.Checkbox(
                            checked = path in state.selectedFolders,
                            onCheckedChange = { viewModel.toggleFolder(path) }
                        )
                        Icon(
                            imageVector = LucideIcons.Folder,
                            contentDescription = null,
                            modifier = Modifier.size(20.dp)
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = entry.name,
                            color = MiuixTheme.colorScheme.onBackground,
                            modifier = Modifier.weight(1f)
                        )
                        Icon(
                            imageVector = LucideIcons.ArrowRight,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
            }
        }
    }

    Spacer(Modifier.height(8.dp))
    TextButton(
        text = stringResource(if (state.busy) R.string.remote_connecting else R.string.remote_save),
        onClick = { viewModel.save("") },
        enabled = !state.busy && state.selectedFolders.isNotEmpty(),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp),
        colors = ButtonDefaults.textButtonColorsPrimary(),
    )
    TextButton(
        text = stringResource(R.string.remote_back_to_settings),
        onClick = viewModel::backToForm,
        enabled = !state.busy,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp),
    )
}

@Composable
private fun RemoteTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    keyboardType: KeyboardType = KeyboardType.Text,
) {
    val inputState = rememberEditorTextFieldState(value, onValueChange)
    TextField(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
        state = inputState,
        label = label,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        lineLimits = TextFieldLineLimits.SingleLine,
    )
}

@Composable
private fun RemotePasswordField(state: RemoteLocationUiState, viewModel: RemoteLocationViewModel) {
    var visible by rememberSaveable { mutableStateOf(false) }
    val inputState = rememberEditorTextFieldState(state.password, viewModel::onPasswordChange)
    val label = stringResource(
        if (state.isEditing && state.hasStoredSecret) R.string.remote_field_password_keep else R.string.remote_field_password
    )
    TextField(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
        state = inputState,
        label = label,
        outputTransformation = if (!visible) {
            OutputTransformation {
                for (index in 0 until length) replace(index, index + 1, "•")
            }
        } else null,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        trailingIcon = {
            IconButton(onClick = { visible = !visible }) {
                Icon(
                    imageVector = if (visible) LucideIcons.EyeOff else LucideIcons.Eye,
                    contentDescription = stringResource(if (visible) R.string.password_hide else R.string.password_show)
                )
            }
        },
        lineLimits = TextFieldLineLimits.SingleLine,
    )
}
