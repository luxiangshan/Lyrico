package com.lonx.lyrico.desktop

import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import androidx.compose.ui.use
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import com.lonx.lyrico.desktop.ui.AppState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.jetbrains.skia.EncodedImageFormat
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Renders the main window headlessly (no Windows here) to catch composition crashes; PNGs go to $LYRICO_SHOTS if set. */
class UiRenderTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun render(state: AppState, name: String) {
        ImageComposeScene(1360, 860, Density(1f)) { AppTheme(false) { App(state) } }.use { scene ->
            scene.render(0)
            Thread.sleep(300)
            val img = scene.render(500_000_000)
            val png = img.encodeToData(EncodedImageFormat.PNG)!!.bytes
            assertTrue(png.size > 1000)
            System.getenv("LYRICO_SHOTS")?.let { File(it).mkdirs(); File(it, "$name.png").writeBytes(png) }
        }
    }

    @Test
    fun rendersLibraryEditorAndBatch() {
        // Needs a GPU/EGL-capable environment; run with LYRICO_SHOTS=<dir> or -Dlyrico.uiTest=true.
        org.junit.Assume.assumeTrue(System.getenv("LYRICO_SHOTS") != null || System.getProperty("lyrico.uiTest") == "true")
        System.setProperty("lyrico.home", File(tmp.root, "home").absolutePath)
        val music = File(tmp.root, "音乐").apply { mkdirs() }
        val cover = CoverArt.fromFile(File(javaClass.getResource("/audio/cover.jpg")!!.toURI()))
        val names = listOf("晴天" to "周杰伦", "七里香" to "周杰伦", "稻香" to "周杰伦", "后来" to "刘若英")
        for ((i, p) in names.withIndex()) {
            val ext = listOf("mp3", "flac", "m4a", "opus")[i]
            val f = File(music, "${p.first}.$ext")
            javaClass.getResourceAsStream("/audio/sample.$ext")!!.use { s -> f.outputStream().use { s.copyTo(it) } }
            TagService.write(f, TagEdit(mapOf(TagField.TITLE to p.first, TagField.ARTIST to p.second, TagField.ALBUM to "专辑 $i"),
                if (i % 2 == 0) "[00:01.00]${p.first} 第一行\n[00:02.00]第二行" else null, CoverChange.Replace(cover)))
        }
        File(music, "七里香.lrc").writeText("[00:00.00]七里香 LRC")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val state = AppState(scope)
        state.addFolder(music)
        val deadline = System.currentTimeMillis() + 20_000
        while (state.songs.size < 4 && System.currentTimeMillis() < deadline) Thread.sleep(100)
        while (state.scanStatus != null && System.currentTimeMillis() < deadline) Thread.sleep(100)
        render(state, "1-library")

        val qi = state.songs.first { it.title == "七里香" }
        state.select(setOf(qi.id))
        while (state.editor == null && state.editorError == null && System.currentTimeMillis() < deadline) Thread.sleep(50)
        assertNotNull(state.editor, state.editorError)
        assertTrue(state.editor!!.lyricsFromLrc)
        render(state, "2-editor")

        state.select(state.songs.map { it.id }.toSet())
        assertNotNull(state.batch)
        render(state, "3-batch")
    }
}
