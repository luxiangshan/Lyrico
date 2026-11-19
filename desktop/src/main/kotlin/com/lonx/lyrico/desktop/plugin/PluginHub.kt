package com.lonx.lyrico.desktop.plugin

import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.ui.AppState
import com.lonx.lyrico.desktop.ui.EditorState

/** Plugin integration (placeholder until the JS runtime is wired in). */
class PluginHub(private val app: AppState) {
    val hasLyricsSources: Boolean get() = false
    val hasCoverSources: Boolean get() = false
    val hasMetadataSources: Boolean get() = false
    fun openLyricsSearch(e: EditorState) {}
    fun openCoverSearch(e: EditorState) {}
    fun openMetadataSearch(e: EditorState) {}
    fun batchMatchLyrics(songs: List<Song>) {}
}
