package com.lonx.lyrico.desktop.plugin

import com.lonx.lyrico.desktop.settings.AppDirs
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** android.util.Base64 subset used by the host API, on java.util.Base64. */
object Base64 {
    const val DEFAULT = 0
    const val NO_PADDING = 1
    const val NO_WRAP = 2
    const val URL_SAFE = 8

    fun encodeToString(bytes: ByteArray, flags: Int): String {
        var enc = if (flags and URL_SAFE != 0) java.util.Base64.getUrlEncoder() else java.util.Base64.getEncoder()
        if (flags and NO_PADDING != 0) enc = enc.withoutPadding()
        return enc.encodeToString(bytes)
    }

    fun decode(text: String, flags: Int): ByteArray {
        val clean = text.filterNot { it.isWhitespace() }
        val urlSafe = flags and URL_SAFE != 0 || clean.contains('-') || clean.contains('_')
        val normalized = if (urlSafe) clean.replace('-', '+').replace('_', '/') else clean
        val padded = normalized + "=".repeat((4 - normalized.length % 4) % 4)
        return java.util.Base64.getDecoder().decode(padded)
    }
}

/** In-memory plugin log (last 500 lines) plus a rolling file in the data folder. */
object PluginLog {
    private val lines = ArrayDeque<String>()
    private val file get() = File(AppDirs.root, "plugin.log")
    private val fmt = DateTimeFormatter.ofPattern("MM-dd HH:mm:ss")

    fun record(tag: String, title: String, message: String, pluginId: String, level: String = "D") {
        val line = "${LocalDateTime.now().format(fmt)} $level [$pluginId] $tag: $title ${message.take(2000)}"
        synchronized(lines) {
            lines.addLast(line)
            while (lines.size > 500) lines.removeFirst()
        }
        try {
            val f = file
            if (f.length() > 2_000_000) f.delete()
            f.appendText(line + "\n")
        } catch (_: Exception) {
        }
    }

    fun recent(): List<String> = synchronized(lines) { lines.toList() }
}

@Serializable
data class PluginConfigOption(val value: String = "", val label: String = "", val summary: String = "")

@Serializable
data class PluginConfigField(
    val key: String,
    val title: String = "",
    val summary: String? = null,
    val group: String = "",
    val type: String = "text",
    val required: Boolean = false,
    val defaultValue: String = "",
    val options: List<PluginConfigOption> = emptyList(),
)

@Serializable
data class PluginI18n(val defaultLocale: String = "en", val resources: Map<String, String> = emptyMap())

@Serializable
data class PluginManifest(
    val id: String,
    val name: String,
    val versionCode: Int = 1,
    val versionName: String = "",
    val apiVersion: Int = 1,
    val minHostApiVersion: Int = 1,
    val author: String = "",
    val description: String = "",
    val entry: String = "source.js",
    val includeDirs: List<String> = emptyList(),
    val icon: String? = null,
    val capabilities: List<String> = emptyList(),
    val configFields: List<PluginConfigField> = emptyList(),
    val i18n: PluginI18n? = null,
    val updateUrl: String? = null,
) {
    val effectiveCapabilities: Set<String> get() = capabilities.toSet().ifEmpty { setOf(CAP_SEARCH_SONGS) }

    companion object {
        const val CAP_SEARCH_SONGS = "searchSongs"
        const val CAP_GET_LYRICS = "getLyrics"
        const val CAP_SEARCH_COVERS = "searchCovers"
        const val PLUGIN_PROTOCOL_VERSION = 5
        const val PLATFORM_API_VERSION = 4
    }
}

val pluginJson = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true; explicitNulls = false }

/** Android-style positional format subset (%1$s, %d, %%). */
object PluginStringFormat {
    private val token = Regex("%(?:([1-9][0-9]*)\\$)?([sd%])")

    fun format(text: String, args: List<Any?>): String {
        var implicit = 0
        return token.replace(text) { m ->
            val type = m.groupValues[2]
            if (type == "%") "%" else {
                val index = m.groupValues[1].toIntOrNull()?.minus(1) ?: implicit++
                val v = args.getOrNull(index)
                if (type == "d") (v as? Number)?.toLong()?.toString() ?: v.toString() else v?.toString() ?: ""
            }
        }
    }
}

class PluginStrings private constructor(private val defaultLocale: String, private val resources: Map<String, Map<String, String>>) {

    fun snapshot(preferences: List<String>): Snapshot {
        val available = resources.keys.sorted()
        val selected = preferences.firstNotNullOfOrNull { pref ->
            val wanted = Locale.forLanguageTag(pref)
            available.firstOrNull { it.equals(wanted.toLanguageTag(), true) }
                ?: available.filter {
                    val c = Locale.forLanguageTag(it)
                    c.language == wanted.language && script(c) == script(wanted)
                }.minByOrNull { Locale.forLanguageTag(it).country.isNotEmpty() }
        } ?: defaultLocale
        val chain = listOf(selected, Locale.forLanguageTag(selected).language, defaultLocale).distinct().mapNotNull { resources[it] }
        return Snapshot(selected, chain)
    }

    class Snapshot(val locale: String, private val chain: List<Map<String, String>>) {
        fun text(value: String): String = when {
            value.startsWith("@@") -> value.drop(1)
            value.startsWith('@') -> chain.firstNotNullOfOrNull { it[value.drop(1)] } ?: value.drop(1)
            else -> value
        }

        fun format(key: String, args: List<Any?>): String {
            val template = chain.firstNotNullOfOrNull { it[key] } ?: error("Unknown plugin string: $key")
            return if (args.isEmpty()) template else PluginStringFormat.format(template, args)
        }
    }

    companion object {
        private fun script(l: Locale) = l.script.ifEmpty {
            if (l.language == "zh") (if (l.country in setOf("TW", "HK", "MO")) "Hant" else "Hans") else ""
        }

        /** Desktop UI is Simplified Chinese. */
        fun preferredLocales(): List<String> = listOf("zh-Hans", "zh-CN", Locale.getDefault().toLanguageTag(), "en")

        fun load(root: File, manifest: PluginManifest): PluginStrings {
            val spec = manifest.i18n ?: return PluginStrings("und", emptyMap())
            val canonical = root.canonicalFile
            val catalogs = spec.resources.mapNotNull { (tag, path) ->
                val f = File(canonical, path).canonicalFile
                if (!f.toPath().startsWith(canonical.toPath()) || !f.isFile) return@mapNotNull null
                tag to (runCatching { pluginJson.decodeFromString<Map<String, String>>(f.readText()) }.getOrNull() ?: return@mapNotNull null)
            }.toMap()
            return PluginStrings(spec.defaultLocale, catalogs)
        }
    }
}
