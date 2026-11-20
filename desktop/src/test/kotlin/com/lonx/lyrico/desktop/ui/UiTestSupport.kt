package com.lonx.lyrico.desktop.ui

import com.lonx.lyrico.desktop.e2e.E2E
import java.io.File

/** Builds an AppState over a real folder of tagged files, the way the app does after 添加文件夹. */
internal fun libraryState(root: File, files: Map<String, (File) -> Unit>): AppState {
    val music = File(root, "music")
    for ((rel, init) in files) {
        val f = E2E.sample(rel.substringAfterLast('.'), File(music, rel))
        init(f)
    }
    System.setProperty("lyrico.home", File(root, "home").absolutePath) // fresh settings/library for this test
    val state = AppState(E2E.uiScope(), File(root, "plugins"))
    state.addFolder(music)
    E2E.waitUntil("scan of ${files.size} files", describe = { "songs=${state.songs.map { it.path }} status=${state.scanStatus} folders=${state.settings.folders}" }) { state.songs.count { it.path.startsWith(music.absolutePath) } == files.size && state.scanStatus == null }
    return state
}

/*
 * AppState is written from a background "UI" thread in these tests, while the app writes it on the Swing thread that
 * also composes. A write racing a composition can leave the test scene showing stale state, so tests re-key the
 * content after waiting for state ("refresh"), which recomposes from the current values like the next frame would.
 */
private val uiTick = androidx.compose.runtime.mutableStateOf(0)

@androidx.compose.runtime.Composable
internal fun Fresh(content: @androidx.compose.runtime.Composable () -> Unit) {
    androidx.compose.runtime.key(uiTick.value) { content() }
}

@OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
internal fun androidx.compose.ui.test.ComposeUiTest.refresh() {
    androidx.compose.runtime.snapshots.Snapshot.sendApplyNotifications()
    uiTick.value++
    waitForIdle()
}

/** Waits for AppState (not the UI) and then refreshes the scene. */
@OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
internal fun androidx.compose.ui.test.ComposeUiTest.awaitState(what: String, timeoutMs: Long = 30_000, cond: () -> Boolean) {
    E2E.waitUntil(what, timeoutMs, cond = cond)
    refresh()
}
