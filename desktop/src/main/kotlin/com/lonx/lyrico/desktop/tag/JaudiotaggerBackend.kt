package com.lonx.lyrico.desktop.tag

import org.jaudiotagger.audio.AudioFile
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.audio.wav.WavOptions
import org.jaudiotagger.audio.wav.WavSaveOptions
import org.jaudiotagger.tag.FieldKey
import org.jaudiotagger.tag.Tag
import org.jaudiotagger.tag.TagOptionSingleton
import org.jaudiotagger.tag.id3.AbstractID3v2Frame
import org.jaudiotagger.tag.id3.AbstractID3v2Tag
import org.jaudiotagger.tag.id3.framebody.FrameBodyUSLT
import org.jaudiotagger.tag.id3.valuepair.TextEncoding
import org.jaudiotagger.tag.images.ArtworkFactory
import org.jaudiotagger.tag.reference.ID3V2Version
import org.jaudiotagger.tag.reference.PictureTypes
import org.jaudiotagger.tag.vorbiscomment.VorbisCommentTag
import org.jaudiotagger.tag.flac.FlacTag
import org.jaudiotagger.tag.wav.WavTag
import org.jaudiotagger.tag.aiff.AiffTag
import java.io.File
import java.util.logging.Level
import java.util.logging.Logger

/** MP3, FLAC, OGG Vorbis, M4A/MP4, WAV, AIFF, WMA, DSF via jaudiotagger (pure Java). */
object JaudiotaggerBackend : TagBackend {

    private val lock = Any()

    init {
        Logger.getLogger("org.jaudiotagger").level = Level.OFF
        val o = TagOptionSingleton.getInstance()
        o.isResetTextEncodingForExistingFrames = true
        o.id3v23DefaultTextEncoding = TextEncoding.UTF_16
        o.id3v24DefaultTextEncoding = TextEncoding.UTF_8
        o.id3v24UnicodeTextEncoding = TextEncoding.UTF_8
        o.isLyrics3Save = false
        o.wavOptions = WavOptions.READ_ID3_UNLESS_ONLY_INFO_AND_SYNC
        o.wavSaveOptions = WavSaveOptions.SAVE_BOTH_AND_SYNC
        o.isPadNumbers = false
    }

    private val keys = mapOf(
        TagField.TITLE to FieldKey.TITLE,
        TagField.ARTIST to FieldKey.ARTIST,
        TagField.ALBUM to FieldKey.ALBUM,
        TagField.ALBUM_ARTIST to FieldKey.ALBUM_ARTIST,
        TagField.TRACK to FieldKey.TRACK,
        TagField.TRACK_TOTAL to FieldKey.TRACK_TOTAL,
        TagField.DISC to FieldKey.DISC_NO,
        TagField.DISC_TOTAL to FieldKey.DISC_TOTAL,
        TagField.YEAR to FieldKey.YEAR,
        TagField.GENRE to FieldKey.GENRE,
        TagField.COMPOSER to FieldKey.COMPOSER,
        TagField.LYRICIST to FieldKey.LYRICIST,
        TagField.COMMENT to FieldKey.COMMENT,
    )

    private fun open(file: File): AudioFile = try {
        AudioFileIO.read(file)
    } catch (e: Exception) {
        throw TagException("无法读取文件「${file.name}」：${e.message ?: e.javaClass.simpleName}", e)
    }

    private fun Tag.safeFirst(key: FieldKey): String = try {
        getFirst(key).orEmpty()
    } catch (_: Exception) {
        ""
    }

    private fun readLyrics(tag: Tag): String {
        var text = tag.safeFirst(FieldKey.LYRICS)
        if (text.isEmpty() && tag is VorbisCommentTag) text = tag.getFirst("UNSYNCEDLYRICS").orEmpty()
        if (text.isEmpty() && tag is FlacTag) text = tag.vorbisCommentTag?.getFirst("UNSYNCEDLYRICS").orEmpty()
        return text
    }

    override fun read(file: File, withCover: Boolean): TagData = synchronized(lock) {
        val af = open(file)
        val tag = af.tag
        val h = af.audioHeader
        val audio = AudioInfo(
            format = h?.format.orEmpty(),
            durationSeconds = h?.trackLength ?: 0,
            bitrateKbps = h?.bitRateAsNumber?.toInt() ?: 0,
            sampleRate = h?.sampleRateAsNumber ?: 0,
            channels = h?.channels.orEmpty(),
        )
        if (tag == null) return TagData(emptyMap(), "", null, false, audio)
        val fields = keys.mapValues { (_, k) -> tag.safeFirst(k) }.filterValues { it.isNotEmpty() }
        val artworks = try { tag.artworkList } catch (_: Exception) { emptyList() }
        val cover = if (withCover) artworks.firstOrNull()?.binaryData?.takeIf { it.isNotEmpty() }?.let {
            val mime = artworks.first().mimeType?.takeIf { m -> m.isNotBlank() } ?: CoverArt.sniffMime(it)
            CoverArt(it, mime)
        } else null
        TagData(fields, readLyrics(tag), cover, artworks.isNotEmpty(), audio)
    }

    override fun write(file: File, edit: TagEdit, options: TagWriteOptions) {
        if (edit.isEmpty) return
        if (!file.canWrite()) throw TagException("文件「${file.name}」是只读的，无法写入")
        synchronized(lock) {
            val o = TagOptionSingleton.getInstance()
            o.iD3V2Version = if (options.id3Version == "2.4") ID3V2Version.ID3_V24 else ID3V2Version.ID3_V23
            val af = open(file)
            val tag = af.tagAndConvertOrCreateAndSetDefault
                ?: throw TagException("「${file.name}」的格式不支持写入标签")
            for ((field, value) in edit.fields) {
                val key = keys.getValue(field)
                val v = value.trim()
                try {
                    if (v.isEmpty()) tag.deleteField(key) else tag.setField(key, v)
                } catch (e: Exception) {
                    throw TagException("${field.label}「$v」无法写入：${e.message ?: e.javaClass.simpleName}", e)
                }
            }
            edit.lyrics?.let { writeLyrics(tag, it, options) }
            when (val c = edit.cover) {
                CoverChange.Keep -> Unit
                CoverChange.Remove -> tag.deleteArtworkField()
                is CoverChange.Replace -> {
                    tag.deleteArtworkField()
                    val art = ArtworkFactory.getNew()
                    art.binaryData = c.art.bytes
                    art.mimeType = c.art.mime
                    art.pictureType = PictureTypes.DEFAULT_ID
                    art.description = ""
                    try { art.setImageFromData() } catch (_: Throwable) { /* size unknown (e.g. webp) */ }
                    try {
                        tag.setField(art)
                    } catch (e: Exception) {
                        throw TagException("封面无法写入：${e.message ?: e.javaClass.simpleName}", e)
                    }
                }
            }
            try {
                af.commit()
            } catch (e: Exception) {
                throw TagException("保存「${file.name}」失败：${e.message ?: e.javaClass.simpleName}", e)
            }
        }
    }

    private fun id3Of(tag: Tag): AbstractID3v2Tag? = when (tag) {
        is AbstractID3v2Tag -> tag
        is WavTag -> tag.iD3Tag ?: WavTag.createDefaultID3Tag().also { tag.setID3Tag(it) }
        is AiffTag -> tag.iD3Tag
        else -> null
    }

    private fun writeLyrics(tag: Tag, text: String, options: TagWriteOptions) {
        val id3 = id3Of(tag)
        if (id3 != null) {
            id3.removeFrame("USLT")
            if (text.isNotEmpty()) {
                val frame: AbstractID3v2Frame = id3.createFrame("USLT")
                val enc = if (id3 is org.jaudiotagger.tag.id3.ID3v24Tag) TextEncoding.UTF_8 else TextEncoding.UTF_16
                frame.body = FrameBodyUSLT(enc, options.usltLanguage.ifBlank { "chi" }.take(3), "", text)
                id3.setFrame(frame)
            }
            return
        }
        if (tag is VorbisCommentTag) tag.deleteField("UNSYNCEDLYRICS")
        if (tag is FlacTag) tag.vorbisCommentTag?.deleteField("UNSYNCEDLYRICS")
        if (text.isEmpty()) tag.deleteField(FieldKey.LYRICS) else tag.setField(FieldKey.LYRICS, text)
    }
}
