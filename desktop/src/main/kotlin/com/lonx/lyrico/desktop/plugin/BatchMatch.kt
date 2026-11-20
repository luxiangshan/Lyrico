package com.lonx.lyrico.desktop.plugin

import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.TagData
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import kotlinx.serialization.Serializable

/** What batch matching may fill. TRACK/DISC include their totals ("3/12"). */
@Serializable
enum class MatchTarget(val label: String) {
    TITLE("标题"), ARTIST("艺术家"), ALBUM("专辑"), ALBUM_ARTIST("专辑艺术家"), TRACK("音轨号"), DISC("碟号"),
    YEAR("年份"), GENRE("流派"), COMPOSER("作曲"), LYRICIST("作词"), LYRICS("歌词"), COVER("封面");

    val isMetadata get() = this != LYRICS && this != COVER

    companion object {
        /** Android BatchMatchConfigDefaults.DEFAULT_ENABLED_TARGETS. */
        val defaults = setOf(TITLE, ARTIST, ALBUM, GENRE, YEAR, TRACK, LYRICS, COVER)
    }
}

@Serializable
enum class MatchWriteMode(val label: String) {
    /** Android SUPPLEMENT: only fields that are empty in the file are filled. */
    SUPPLEMENT("补充（只填空白字段）"),
    /** Android OVERWRITE: fields the matched result HAS replace the file's values; fields it lacks are kept. */
    OVERWRITE("覆盖（用匹配结果覆盖）"),
}

data class BatchMatchConfig(
    val targets: Set<MatchTarget> = MatchTarget.defaults,
    val mode: MatchWriteMode = MatchWriteMode.SUPPLEMENT,
    val preferFileName: Boolean = false,
    val concurrency: Int = 3,
)

/** One plugin as the matcher uses it (implemented over PluginSource; tests can fake it). */
interface MatchSource {
    val id: String
    val name: String
    val searchesSongs: Boolean
    val providesLyrics: Boolean
    val searchesCovers: Boolean
    fun searchSongs(keyword: String, pageSize: Int): List<PluginSong>
    fun lyrics(song: PluginSong): List<LyricsCandidate>
    fun searchCovers(keyword: String): List<CoverCandidate>
}

enum class MatchStatus(val label: String) { MATCHED("已匹配"), NOT_FOUND("未匹配"), SKIPPED("跳过"), FAILED("失败") }

class SongMatchResult(
    val song: Song,
    val status: MatchStatus,
    /** e.g. "QQ音乐 0.91：专辑、年份、歌词、封面" / "最高分 0.58 低于阈值" */
    val detail: String,
    val written: List<MatchTarget> = emptyList(),
    val updated: Song? = null,
)

/** What to write for one song: tag fields (never empty values), lyrics text, cover bytes. */
class MatchPlan(val fields: Map<TagField, String>, val lyrics: String?, val cover: CoverArt?, val written: List<MatchTarget>, val detail: String) {
    val isEmpty get() = fields.isEmpty() && lyrics == null && cover == null
    fun tagEdit(withLyrics: Boolean): TagEdit = TagEdit(
        fields = fields,
        lyrics = if (withLyrics) lyrics else null,
        cover = cover?.let { com.lonx.lyrico.desktop.tag.CoverChange.Replace(it) } ?: com.lonx.lyrico.desktop.tag.CoverChange.Keep,
    )
}

/**
 * Batch matching, ported from the Android processors (MatchMetadataProcessor, MatchLyricsProcessor, MatchCoverProcessor):
 * - metadata: every query × every ticked metadata plugin (pageSize 2), Android scoring; stops early at final ≥ 0.92 and
 *   text ≥ 0.86; accepted only at final ≥ 0.76 and text ≥ 0.72. Lyrics/cover come from that same result when possible.
 * - lyrics (if still needed): best scored song per lyrics plugin, accepted at ≥ 0.72.
 * - cover (if still needed): best scored cover per cover plugin, accepted at ≥ 0.65.
 * Data safety: a value is only ever SET from a non-blank result; nothing is ever cleared. Supplement mode skips fields
 * that already have a value; overwrite mode only replaces fields the result actually has.
 */
object BatchMatcher {
    const val META_MIN_FINAL = 0.76
    const val META_MIN_TEXT = 0.72
    const val META_EARLY_FINAL = 0.92
    const val META_EARLY_TEXT = 0.86
    const val LYRICS_MIN = 0.72
    const val COVER_MIN = 0.65

    fun local(song: Song, tag: TagData): MatchLocalSong = MatchLocalSong(
        fileName = song.fileName,
        title = tag[TagField.TITLE].ifBlank { song.title }.ifBlank { null },
        artist = tag[TagField.ARTIST].ifBlank { song.artist }.ifBlank { null },
        durationMs = (tag.audio.durationSeconds.takeIf { it > 0 } ?: song.durationSeconds) * 1000L,
    )

    private fun current(tag: TagData, t: MatchTarget): String = when (t) {
        MatchTarget.TITLE -> tag[TagField.TITLE]
        MatchTarget.ARTIST -> tag[TagField.ARTIST]
        MatchTarget.ALBUM -> tag[TagField.ALBUM]
        MatchTarget.ALBUM_ARTIST -> tag[TagField.ALBUM_ARTIST]
        MatchTarget.TRACK -> tag[TagField.TRACK]
        MatchTarget.DISC -> tag[TagField.DISC]
        MatchTarget.YEAR -> tag[TagField.YEAR]
        MatchTarget.GENRE -> tag[TagField.GENRE]
        MatchTarget.COMPOSER -> tag[TagField.COMPOSER]
        MatchTarget.LYRICIST -> tag[TagField.LYRICIST]
        MatchTarget.LYRICS -> tag.lyrics
        MatchTarget.COVER -> if (tag.hasCover) "cover" else ""
    }

    /** Targets that still need a value under [cfg] (supplement: only blank ones). */
    fun needed(tag: TagData, cfg: BatchMatchConfig): Set<MatchTarget> =
        if (cfg.mode == MatchWriteMode.OVERWRITE) cfg.targets else cfg.targets.filter { current(tag, it).isBlank() }.toSet()

    /** Values a plugin song offers, keyed by target (blank values dropped). Android: SongSearchResult.normalizedFields(). */
    fun offered(s: PluginSong): Map<MatchTarget, String> {
        val f = s.fields
        fun pick(vararg v: String?) = v.firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()
        val m = linkedMapOf(
            MatchTarget.TITLE to pick(f["title"], s.title),
            MatchTarget.ARTIST to pick(f["artist"], s.artist),
            MatchTarget.ALBUM to pick(f["album"], s.album),
            MatchTarget.ALBUM_ARTIST to pick(f["album_artist"], f["albumArtist"]),
            MatchTarget.TRACK to pick(f["track_number"], s.trackNumber),
            MatchTarget.DISC to pick(f["disc_number"]),
            MatchTarget.YEAR to pick(f["date"], f["year"], s.date),
            MatchTarget.GENRE to pick(f["genre"]),
            MatchTarget.COMPOSER to pick(f["composer"]),
            MatchTarget.LYRICIST to pick(f["lyricist"]),
        )
        return m.filterValues { it.isNotBlank() }
    }

    /** Tag fields to write for [target] = [value] (TRACK "3/12" -> 音轨号 + 音轨总数). Empty parts are not written. */
    private fun fieldsFor(target: MatchTarget, value: String, tag: TagData, mode: MatchWriteMode): Map<TagField, String> {
        fun pair(n: TagField, t: TagField): Map<TagField, String> {
            val (num, total) = com.lonx.lyrico.desktop.tag.splitNumberPair(value)
            val out = LinkedHashMap<TagField, String>()
            if (num.isNotBlank()) out[n] = num
            if (total.isNotBlank() && (mode == MatchWriteMode.OVERWRITE || tag[t].isBlank())) out[t] = total
            return out
        }
        val year = { Regex("""\d{4}""").find(value)?.value ?: value }
        return when (target) {
            MatchTarget.TITLE -> mapOf(TagField.TITLE to value)
            MatchTarget.ARTIST -> mapOf(TagField.ARTIST to value)
            MatchTarget.ALBUM -> mapOf(TagField.ALBUM to value)
            MatchTarget.ALBUM_ARTIST -> mapOf(TagField.ALBUM_ARTIST to value)
            MatchTarget.TRACK -> pair(TagField.TRACK, TagField.TRACK_TOTAL)
            MatchTarget.DISC -> pair(TagField.DISC, TagField.DISC_TOTAL)
            MatchTarget.YEAR -> mapOf(TagField.YEAR to year())
            MatchTarget.GENRE -> mapOf(TagField.GENRE to value)
            MatchTarget.COMPOSER -> mapOf(TagField.COMPOSER to value)
            MatchTarget.LYRICIST -> mapOf(TagField.LYRICIST to value)
            MatchTarget.LYRICS, MatchTarget.COVER -> emptyMap()
        }.filterValues { it.isNotBlank() }
    }

    private class Scored(val song: PluginSong, val source: MatchSource, val detail: MatchScoreDetail)

    /**
     * Finds the best match for one song and returns what to write (or why nothing).
     * [download] fetches cover bytes; [log] receives per-source problems (shown in the result detail).
     */
    fun plan(
        song: Song,
        tag: TagData,
        cfg: BatchMatchConfig,
        metadataSources: List<MatchSource>,
        lyricsSources: List<MatchSource>,
        coverSources: List<MatchSource>,
        download: (String) -> ByteArray,
        isImage: (ByteArray) -> Boolean = { true },
    ): Pair<MatchStatus, MatchPlan> {
        val need = needed(tag, cfg)
        if (need.isEmpty()) return MatchStatus.SKIPPED to MatchPlan(emptyMap(), null, null, emptyList(), "所选字段都已有值（补充模式）")
        val local = local(song, tag)
        val queries = MusicMatch.buildSearchQueries(local, cfg.preferFileName)
        if (queries.isEmpty()) return MatchStatus.NOT_FOUND to MatchPlan(emptyMap(), null, null, emptyList(), "没有可用于搜索的标题/文件名")
        val errors = ArrayList<String>()
        val fields = LinkedHashMap<TagField, String>()
        val written = ArrayList<MatchTarget>()
        var lyrics: String? = null
        var cover: CoverArt? = null
        val notes = ArrayList<String>()
        var bestSeen = 0.0

        // ---- metadata (Android MatchMetadataProcessor)
        val metaSources = metadataSources.filter { it.searchesSongs }
        var match: Scored? = null
        if (metaSources.isNotEmpty() && (need.any { it.isMetadata } || MatchTarget.LYRICS in need || MatchTarget.COVER in need)) {
            var best: Scored? = null
            search@ for (q in queries) {
                for (src in metaSources) {
                    val results = try { src.searchSongs(q, 2) } catch (e: Exception) { errors += "${src.name}：${e.message ?: e.javaClass.simpleName}"; emptyList() }
                    val top = results.mapIndexed { i, r ->
                        Scored(r, src, MusicMatch.calculateMatchScoreDetail(MatchCandidate(r.title, r.artist, r.durationMs), local, cfg.preferFileName, rankIndex = i))
                    }.maxByOrNull { it.detail.finalScore } ?: continue
                    if (best == null || top.detail.finalScore > best.detail.finalScore) best = top
                    if (top.detail.finalScore >= META_EARLY_FINAL && top.detail.textScore >= META_EARLY_TEXT) { best = top; break@search }
                }
            }
            bestSeen = best?.detail?.finalScore ?: 0.0
            if (best != null && best.detail.finalScore >= META_MIN_FINAL && best.detail.textScore >= META_MIN_TEXT) match = best
        }
        if (match != null) {
            val offered = offered(match.song)
            for (t in need.filter { it.isMetadata }) {
                val v = offered[t] ?: continue // the result lacks this value: keep the file's value
                val fs = fieldsFor(t, v, tag, cfg.mode).filter { (f, nv) -> nv != tag[f] && !(f == TagField.YEAR && tag[f].startsWith(nv)) } // "2003" never downgrades "2003-05-01"
                if (fs.isNotEmpty()) { fields.putAll(fs); written += t }
            }
            if (MatchTarget.LYRICS in need && match.source.providesLyrics) {
                lyrics = try { match.source.lyrics(match.song).firstOrNull { it.text.isNotBlank() }?.text } catch (e: Exception) { errors += "${match.source.name} 歌词：${e.message}"; null }
                if (lyrics != null) notes += "歌词来自 ${match.source.name}"
            }
            if (MatchTarget.COVER in need && match.song.picUrl.isNotBlank()) {
                cover = fetchCover(match.song.picUrl, download, isImage, errors, match.source.name)
            }
        }

        // ---- lyrics (Android MatchLyricsProcessor)
        if (MatchTarget.LYRICS in need && lyrics == null) {
            var best: Pair<LyricsCandidate, Double>? = null
            var bestName = ""
            for (src in lyricsSources.filter { it.providesLyrics }) {
                try {
                    val cand: Pair<LyricsCandidate, Double>? = if (src.searchesSongs) {
                        val results = queries.flatMap { q -> runCatching { src.searchSongs(q, 3) }.getOrDefault(emptyList()) }
                        val top = results.mapIndexed { i, r -> r to MusicMatch.calculateMatchScore(MatchCandidate(r.title, r.artist, r.durationMs), local, cfg.preferFileName, rankIndex = i) }
                            .maxByOrNull { it.second }
                        top?.let { (r, score) -> src.lyrics(r).firstOrNull { it.text.isNotBlank() }?.let { it to score } }
                    } else {
                        val request = PluginSong(src.id, src.name, "", local.title.orEmpty().ifBlank { song.baseName }, local.artist.orEmpty(), tag[TagField.ALBUM], local.durationMs, "", "", "", emptyMap(), null)
                        src.lyrics(request).filter { it.text.isNotBlank() }.mapIndexed { i, c ->
                            c to MusicMatch.calculateMatchScore(MatchCandidate(c.title.ifBlank { request.title }, c.artist.ifBlank { request.artist }, c.durationMs), local, cfg.preferFileName, rankIndex = i)
                        }.maxByOrNull { it.second }
                    }
                    if (cand != null && cand.second > (best?.second ?: Double.NEGATIVE_INFINITY)) { best = cand; bestName = src.name }
                } catch (e: Exception) {
                    errors += "${src.name} 歌词：${e.message ?: e.javaClass.simpleName}"
                }
            }
            if (best != null && best.second >= LYRICS_MIN) { lyrics = best.first.text; notes += "歌词来自 $bestName %.2f".format(best.second) }
            else if (best != null) notes += "歌词最高分 %.2f 低于 %.2f".format(best.second, LYRICS_MIN)
        }

        // ---- cover (Android MatchCoverProcessor)
        if (MatchTarget.COVER in need && cover == null) {
            var best: Pair<CoverCandidate, Double>? = null
            var bestName = ""
            for (src in coverSources.filter { it.searchesCovers }) {
                try {
                    src.searchCovers(queries.first()).filter { it.url.isNotBlank() }.mapIndexed { i, c ->
                        c to MusicMatch.calculateMatchScore(MatchCandidate(c.title, c.artist), local, cfg.preferFileName, rankIndex = i)
                    }.maxByOrNull { it.second }?.let { if (it.second > (best?.second ?: Double.NEGATIVE_INFINITY)) { best = it; bestName = src.name } }
                } catch (e: Exception) {
                    errors += "${src.name} 封面：${e.message ?: e.javaClass.simpleName}"
                }
            }
            val b = best
            if (b != null && b.second >= COVER_MIN) { cover = fetchCover(b.first.url, download, isImage, errors, bestName); if (cover != null) notes += "封面来自 $bestName %.2f".format(b.second) }
            else if (b != null) notes += "封面最高分 %.2f 低于 %.2f".format(b.second, COVER_MIN)
        }

        lyrics = lyrics?.let { LrcFiles.normalize(it).trimEnd() }?.takeIf { it.isNotBlank() }
        if (lyrics != null && LrcFiles.normalize(tag.lyrics).trimEnd() == lyrics) lyrics = null
        if (lyrics != null) written += MatchTarget.LYRICS
        if (cover != null) written += MatchTarget.COVER
        val head = match?.let { "${it.source.name} %.2f".format(it.detail.finalScore) }
        val err = if (errors.isEmpty()) "" else "（${errors.take(2).joinToString("；")}）"
        val plan = MatchPlan(fields, lyrics, cover, written, "")
        return when {
            !plan.isEmpty -> MatchStatus.MATCHED to MatchPlan(fields, lyrics, cover, written,
                listOfNotNull(head, written.joinToString("、") { it.label }.let { "写入 $it" }).joinToString("：") + notes.joinToString("") { "；$it" } + err)
            match != null -> MatchStatus.SKIPPED to MatchPlan(emptyMap(), null, null, emptyList(), "$head：结果与现有信息相同或缺少所选字段，未修改" + notes.joinToString("") { "；$it" } + err)
            errors.isNotEmpty() && bestSeen == 0.0 && notes.isEmpty() -> MatchStatus.FAILED to MatchPlan(emptyMap(), null, null, emptyList(), errors.take(3).joinToString("；"))
            else -> MatchStatus.NOT_FOUND to MatchPlan(emptyMap(), null, null, emptyList(),
                (if (bestSeen > 0) "最高分 %.2f 低于阈值 %.2f".format(bestSeen, META_MIN_FINAL) else if (metaSources.isEmpty() && need.any { it.isMetadata }) "没有可搜索歌曲信息的插件" else "没有结果") +
                    notes.joinToString("") { "；$it" } + err)
        }
    }

    private fun fetchCover(url: String, download: (String) -> ByteArray, isImage: (ByteArray) -> Boolean, errors: MutableList<String>, name: String): CoverArt? = try {
        val bytes = download(url)
        if (bytes.isNotEmpty() && isImage(bytes)) CoverArt(bytes, CoverArt.sniffMime(bytes)) else { errors += "$name 封面不是有效图片"; null }
    } catch (e: Exception) {
        errors += "$name 封面下载失败：${e.message ?: e.javaClass.simpleName}"; null
    }
}
