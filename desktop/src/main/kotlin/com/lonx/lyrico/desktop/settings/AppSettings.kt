package com.lonx.lyrico.desktop.settings

import com.lonx.lyrico.desktop.lyrics.LineEnding
import com.lonx.lyrico.desktop.lyrics.LrcConflict
import com.lonx.lyrico.desktop.lyrics.LrcWriteOptions
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.tag.TagWriteOptions
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

@Serializable
data class AppSettings(
    val folders: List<String> = emptyList(),
    val lyricsTarget: LyricsTarget = LyricsTarget.TAG,
    val lrcBom: Boolean = false,
    val lrcLineEnding: LineEnding = LineEnding.LF,
    val usltLanguage: String = "chi",
    val id3Version: String = "2.3",
    val autoLoadAdjacentLrc: Boolean = true,
    /** Overwrite / skip / add a number when the exported .lrc already exists. */
    val lrcExportConflict: LrcConflict = LrcConflict.OVERWRITE,
    /** Last directory chosen in the LRC export dialog. */
    val lrcExportDir: String? = null,
    /** Pre-select [lrcExportDir] next time (otherwise every export starts with "song folder"). */
    val rememberLrcExportDir: Boolean = false,
    val sortKey: String = "TITLE",
    val sortDescending: Boolean = false,
    val darkTheme: Boolean = false,
    val scanThreads: Int = 4,
    val pluginIncludeTranslation: Boolean = false,
    val pluginWordByWord: Boolean = false,
    val pluginCatalogUrl: String = "https://github.com/Replica0110/Lyrico-Plugins/releases/latest/download/catalog.json",
    val batchSkipExistingLyrics: Boolean = true,
) {
    val tagOptions get() = TagWriteOptions(id3Version = id3Version, usltLanguage = usltLanguage)
    val lrcOptions get() = LrcWriteOptions(bom = lrcBom, lineEnding = lrcLineEnding)
}

/** %APPDATA%\LyricoMod on Windows, ~/.lyrico-mod elsewhere. */
object AppDirs {
    /** Re-read on each access so tests can point every AppState at its own folder via -Dlyrico.home. */
    val root: File get() {
        val override = System.getProperty("lyrico.home")
        val dir = when {
            override != null -> File(override)
            System.getenv("APPDATA") != null -> File(System.getenv("APPDATA"), "LyricoMod")
            else -> File(System.getProperty("user.home"), ".lyrico-mod")
        }
        dir.mkdirs(); return dir
    }
    val cache: File get() = File(root, "cache").apply { mkdirs() }
    val thumbs: File get() = File(cache, "thumbs").apply { mkdirs() }
    val remoteFiles: File get() = File(cache, "remote").apply { mkdirs() }
    val plugins: File get() = File(root, "plugins").apply { mkdirs() }
}

val appJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    prettyPrint = true
    coerceInputValues = true
}

object SettingsStore {
    private val file get() = File(AppDirs.root, "settings.json")

    fun load(): AppSettings = try {
        if (file.isFile) appJson.decodeFromString(AppSettings.serializer(), file.readText()) else AppSettings()
    } catch (_: Exception) {
        AppSettings()
    }

    fun save(s: AppSettings) {
        val tmp = File(file.parentFile, "settings.json.tmp")
        tmp.writeText(appJson.encodeToString(AppSettings.serializer(), s))
        java.nio.file.Files.move(tmp.toPath(), file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
    }
}
