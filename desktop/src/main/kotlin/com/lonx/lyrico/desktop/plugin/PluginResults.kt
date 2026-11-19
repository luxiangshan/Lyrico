package com.lonx.lyrico.desktop.plugin

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/** A song returned by a plugin's searchSongs. [raw] is passed back to getLyrics unchanged. */
data class PluginSong(
    val sourceId: String,
    val sourceName: String,
    val id: String,
    val title: String,
    val artist: String,
    val album: String,
    val durationMs: Long,
    val date: String,
    val trackNumber: String,
    val picUrl: String,
    val fields: Map<String, String>,
    val internal: JsonObject?,
) {
    val year: String get() = Regex("""\d{4}""").find(date)?.value ?: date
}

data class LyricsCandidate(
    val sourceId: String,
    val sourceName: String,
    val title: String,
    val artist: String,
    val album: String,
    val date: String,
    val type: String,
    /** Converted text ready to store (LRC, or plain text when untimed). */
    val text: String,
    val durationMs: Long = 0,
)

data class CoverCandidate(
    val sourceId: String,
    val sourceName: String,
    val title: String,
    val artist: String,
    val album: String,
    val year: String,
    val url: String,
)

data class LyricsFormatOptions(val includeTranslation: Boolean = false, val wordByWord: Boolean = false)

internal object J {
    fun str(e: JsonElement?): String = when (e) {
        null, JsonNull -> ""
        is JsonPrimitive -> e.contentOrNull.orEmpty()
        is JsonArray -> e.mapNotNull { x -> str(x).takeIf { it.isNotBlank() } }.joinToString("/")
        is JsonObject -> str(e["name"] ?: e["title"])
    }

    fun first(o: JsonObject, vararg keys: String): String = keys.firstNotNullOfOrNull { k -> str(o[k]).takeIf { it.isNotBlank() } }.orEmpty()

    fun long(o: JsonObject, vararg keys: String): Long = keys.firstNotNullOfOrNull { k ->
        val p = o[k] as? JsonPrimitive ?: return@firstNotNullOfOrNull null
        p.longOrNull ?: p.doubleOrNull?.toLong() ?: p.contentOrNull?.toLongOrNull()
    } ?: 0L

    fun items(e: JsonElement?): List<JsonElement> = when (e) {
        is JsonArray -> e.toList()
        is JsonObject -> {
            val inner = listOf("items", "results", "songs", "data", "candidates").firstNotNullOfOrNull { e[it] as? JsonArray }
            inner?.toList() ?: if (e.isEmpty() || e["notFound"] != null) emptyList() else listOf(e)
        }
        is JsonPrimitive -> if (e.isString && e.content.isNotBlank()) listOf(e) else emptyList()
        else -> emptyList()
    }

    fun strMap(e: JsonElement?): Map<String, String> = (e as? JsonObject)?.mapValues { str(it.value) }?.filterValues { it.isNotBlank() }.orEmpty()
}

object PluginResultParser {

    fun songs(sourceId: String, sourceName: String, e: JsonElement?, separator: String = "/"): List<PluginSong> =
        J.items(e).mapNotNull { it as? JsonObject }.map { o ->
            val fields = J.strMap(o["fields"])
            val artist = when (val a = o["artist"] ?: o["artists"] ?: o["singer"]) {
                is JsonArray -> a.map { J.str(it) }.filter { it.isNotBlank() }.joinToString(separator)
                else -> J.str(a)
            }.ifBlank { fields["artist"].orEmpty() }
            PluginSong(
                sourceId, sourceName,
                id = J.first(o, "id", "songId", "trackId"),
                title = J.first(o, "title", "name", "songName").ifBlank { fields["title"].orEmpty() },
                artist = artist,
                album = J.first(o, "album", "albumName").ifBlank { fields["album"].orEmpty() },
                durationMs = J.long(o, "duration", "durationMs", "duration_ms"),
                date = J.first(o, "date", "releaseDate", "release_date", "year").ifBlank { fields["date"].orEmpty() },
                trackNumber = J.first(o, "trackNumber", "trackerNumber", "track_number").ifBlank { fields["track_number"].orEmpty() },
                picUrl = J.first(o, "picUrl", "coverUrl", "cover_url", "artworkUrl").ifBlank { fields["cover_url"].orEmpty() },
                fields = fields,
                internal = o["internal"] as? JsonObject,
            )
        }

    fun covers(sourceId: String, sourceName: String, e: JsonElement?): List<CoverCandidate> =
        J.items(e).mapNotNull { it as? JsonObject }.mapNotNull { o ->
            val fields = J.strMap(o["fields"])
            val url = J.first(o, "picUrl", "coverUrl", "cover_url", "artworkUrl", "url").ifBlank { fields["cover_url"].orEmpty() }
            if (url.isBlank()) null else CoverCandidate(
                sourceId, sourceName,
                title = J.first(o, "title", "name", "songName"),
                artist = J.str(o["artist"] ?: o["artists"] ?: o["singer"]),
                album = J.first(o, "album", "albumName"),
                year = J.first(o, "year", "date", "releaseDate").let { Regex("""\d{4}""").find(it)?.value ?: it },
                url = url,
            )
        }

    fun lyrics(sourceId: String, sourceName: String, e: JsonElement?, fallback: PluginSong?, options: LyricsFormatOptions): List<LyricsCandidate> =
        J.items(e).mapNotNull { item ->
            val (type, text, tags) = when (item) {
                is JsonPrimitive -> Triple("rawPlainLrc", item.content, emptyMap())
                is JsonObject -> {
                    val type = J.str(item["type"]).ifBlank { "structured" }
                    Triple(type, LyricsConverter.convert(type, item, options), J.strMap(item["tags"]))
                }
                else -> return@mapNotNull null
            }
            if (text.isBlank()) return@mapNotNull null
            LyricsCandidate(
                sourceId, sourceName,
                title = tags["ti"] ?: fallback?.title.orEmpty(),
                artist = tags["ar"] ?: fallback?.artist.orEmpty(),
                album = tags["al"] ?: fallback?.album.orEmpty(),
                date = tags["date"] ?: fallback?.date.orEmpty(),
                type = type,
                text = text,
                durationMs = fallback?.durationMs ?: 0,
            )
        }
}

/** Converts plugin lyrics payloads to LRC text. */
object LyricsConverter {

    fun time(ms: Long): String {
        val t = ms.coerceAtLeast(0)
        return "%02d:%02d.%02d".format(t / 60000, (t / 1000) % 60, (t % 1000) / 10)
    }

    private class Line(val start: Long, val text: String, val words: List<Triple<Long, Long, String>>)

    private fun parseLines(e: JsonElement?): List<Line> = (e as? JsonArray)?.mapNotNull { l ->
        val a = l as? JsonArray ?: return@mapNotNull null
        val start = (a.getOrNull(0) as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() } ?: return@mapNotNull null
        when (val body = a.getOrNull(2)) {
            is JsonArray -> {
                val words = body.mapNotNull { w ->
                    val wa = w as? JsonArray ?: return@mapNotNull null
                    val ws = (wa.getOrNull(0) as? JsonPrimitive)?.longOrNull ?: start
                    val we = (wa.getOrNull(1) as? JsonPrimitive)?.longOrNull ?: ws
                    Triple(ws, we, J.str(wa.getOrNull(2)))
                }
                Line(start, words.joinToString("") { it.third }, words)
            }
            else -> Line(start, J.str(body), emptyList())
        }
    }.orEmpty()

    fun convert(type: String, o: JsonObject, options: LyricsFormatOptions): String = when (type) {
        "structured" -> structured(o, options)
        "rawPlainLrc" -> J.str(o["rawPlainLrc"])
        "rawVerbatimLrc", "rawEnhancedLrc", "rawMultiPersonEnhancedLrc" -> {
            val raw = J.str(o[type])
            if (options.wordByWord) raw else lineLevel(raw)
        }
        "rawTtml" -> ttmlToLrc(J.str(o["rawTtml"]))
        else -> J.str(o[type]).ifBlank { J.str(o["rawPlainLrc"]) }
    }.replace("\r\n", "\n").trim('\n')

    private fun structured(o: JsonObject, options: LyricsFormatOptions): String {
        val original = parseLines(o["original"])
        val translated = if (options.includeTranslation) parseLines(o["translated"]) else emptyList()
        val byStart = translated.associateBy { it.start }
        val sb = StringBuilder()
        for ((i, l) in original.withIndex()) {
            if (options.wordByWord && l.words.size > 1) {
                sb.append('[').append(time(l.start)).append(']')
                for (w in l.words) sb.append('<').append(time(w.first)).append('>').append(w.third)
                sb.append('<').append(time(l.words.last().second)).append('>')
            } else {
                sb.append('[').append(time(l.start)).append(']').append(l.text)
            }
            sb.append('\n')
            val tr = byStart[l.start] ?: if (translated.size == original.size) translated[i] else null
            if (tr != null && tr.text.isNotBlank() && tr.text != "//") sb.append('[').append(time(l.start)).append(']').append(tr.text).append('\n')
        }
        return sb.toString()
    }

    private val lineTime = Regex("""^((?:\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?])+)(.*)$""")
    private val inlineTags = Regex("""<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>|\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?]|\(\d+,\d+(?:,\d+)?\)""")

    /** Word-timed LRC -> one timestamp per line. */
    fun lineLevel(raw: String): String = raw.replace("\r\n", "\n").lines().joinToString("\n") { line ->
        val m = lineTime.find(line.trim())
        if (m == null) line else m.groupValues[1].let { stamps ->
            val first = Regex("""\[[^]]+]""").find(stamps)!!.value
            first + inlineTags.replace(m.groupValues[2], "").replace(Regex("""^v\d+:\s*"""), "")
        }
    }

    private fun ttmlTime(v: String): Long? {
        val s = v.trim()
        if (s.endsWith("ms")) return s.dropLast(2).toDoubleOrNull()?.toLong()
        if (s.endsWith("s")) return s.dropLast(1).toDoubleOrNull()?.times(1000)?.toLong()
        val parts = s.split(':')
        return try {
            when (parts.size) {
                1 -> (parts[0].toDouble() * 1000).toLong()
                2 -> (parts[0].toLong() * 60000 + parts[1].toDouble() * 1000).toLong()
                else -> (parts[0].toLong() * 3600000 + parts[1].toLong() * 60000 + parts[2].toDouble() * 1000).toLong()
            }
        } catch (_: Exception) { null }
    }

    /** Minimal TTML -> line LRC (original track only; ttm:role x-translation/x-roman spans dropped). */
    fun ttmlToLrc(ttml: String): String {
        val p = Regex("""<p\b([^>]*)>(.*?)</p>""", RegexOption.DOT_MATCHES_ALL)
        val sb = StringBuilder()
        for (m in p.findAll(ttml)) {
            val begin = Regex("""\bbegin="([^"]+)"""").find(m.groupValues[1])?.groupValues?.get(1)?.let { ttmlTime(it) } ?: continue
            var body = m.groupValues[2]
            body = body.replace(Regex("""<span[^>]*ttm:role="x-(?:translation|roman|bg)"[^>]*>.*?</span>""", RegexOption.DOT_MATCHES_ALL), "")
            val text = body.replace(Regex("<[^>]+>"), "").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                .replace("&apos;", "'").replace("&quot;", "\"").replace(Regex("\\s+"), " ").trim()
            sb.append('[').append(time(begin)).append(']').append(text).append('\n')
        }
        return sb.toString()
    }
}
