package com.lonx.lyrico.desktop.tag

import org.jaudiotagger.audio.AudioFile
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.audio.mp3.MP3File
import org.jaudiotagger.tag.id3.ID3v23Tag
import org.jaudiotagger.tag.id3.ID3v24Tag
import org.jaudiotagger.audio.wav.WavOptions
import org.jaudiotagger.audio.wav.WavSaveOptions
import org.jaudiotagger.tag.FieldKey
import org.jaudiotagger.tag.Tag
import org.jaudiotagger.tag.TagOptionSingleton
import org.jaudiotagger.tag.id3.AbstractID3v2Frame
import org.jaudiotagger.tag.id3.AbstractID3v2Tag
import org.jaudiotagger.tag.id3.framebody.FrameBodyCOMM
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
        // the front cover (type 3) when the file has several pictures, else the first one
        val front = artworks.firstOrNull { it.pictureType == PictureTypes.DEFAULT_ID && it.binaryData?.isNotEmpty() == true } ?: artworks.firstOrNull()
        val cover = if (withCover) front?.binaryData?.takeIf { it.isNotEmpty() }?.let {
            val mime = front.mimeType?.takeIf { m -> m.isNotBlank() } ?: CoverArt.sniffMime(it)
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
            val tag = writableTag(af)
            for ((field, value) in edit.fields) {
                val key = keys.getValue(field)
                val v = value.trim()
                try {
                    if (field == TagField.COMMENT && tag is AbstractID3v2Tag) setId3Comment(tag, v)
                    else if (v.isEmpty()) tag.deleteField(key) else tag.setField(key, v)
                } catch (e: Exception) {
                    throw TagException("${field.label}「$v」无法写入：${e.message ?: e.javaClass.simpleName}", e)
                }
            }
            if (af is MP3File) syncId3v1(af, edit)
            edit.lyrics?.let { writeLyrics(tag, it, options) }
            when (val c = edit.cover) {
                CoverChange.Keep -> Unit
                CoverChange.Remove -> tag.deleteArtworkField()
                is CoverChange.Replace -> {
                    // Only the front cover is replaced: other pictures (back cover, booklet, artist…) are put back after it.
                    val others = otherPictures(tag)
                    tag.deleteArtworkField()
                    val art = ArtworkFactory.getNew()
                    art.binaryData = c.art.bytes
                    art.mimeType = c.art.mime
                    art.pictureType = PictureTypes.DEFAULT_ID
                    art.description = ""
                    // jaudiotagger sizes images with ImageIO, which cannot read WebP; use our own header parser.
                    val size = ImageSize.of(c.art.bytes)
                    if (size != null) { art.width = size.first; art.height = size.second }
                    else try { art.setImageFromData() } catch (_: Throwable) { }
                    try {
                        if (tag is FlacTag) {
                            // FlacTag.createField(Artwork) calls setImageFromData() unconditionally (NPE for WebP).
                            tag.setField(tag.createArtworkField(c.art.bytes, PictureTypes.DEFAULT_ID, c.art.mime, "", art.width, art.height, 24, 0))
                        } else if (tag is VorbisCommentTag) {
                            // VorbisCommentTag.createField(Artwork) has the same ImageIO dependency.
                            tag.setField(tag.createField(org.jaudiotagger.tag.vorbiscomment.VorbisCommentFieldKey.METADATA_BLOCK_PICTURE, VorbisComments.encodePicture(c.art)))
                        } else {
                            tag.setField(art)
                        }
                        for (o in others) tag.addField(o)
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

    /**
     * The tag to edit. An existing ID3v2.3/2.4 tag is edited IN ITS OWN VERSION: converting (e.g. 2.4 -> 2.3 because the
     * setting says 2.3) rewrites frames the user never touched (TDRC -> TYER+TDAT, dropped 2.4-only frames). The ID3
     * version setting only applies to files that get a new ID3v2 tag (or an old 2.2 tag, which jaudiotagger cannot write).
     * An MP3 that only has ID3v1 gets a v2 tag pre-filled from the v1 values, so they are not hidden by the new tag.
     */
    private fun writableTag(af: AudioFile): Tag {
        if (af is MP3File) {
            val v2 = af.iD3v2Tag
            if (v2 is ID3v23Tag || v2 is ID3v24Tag) return v2
            val tag = af.tagAndConvertOrCreateAndSetDefault ?: throw TagException("「${af.file.name}」无法创建 ID3 标签")
            val v1 = af.iD3v1Tag
            if (v2 == null && v1 != null) {
                for (k in listOf(FieldKey.TITLE, FieldKey.ARTIST, FieldKey.ALBUM, FieldKey.YEAR, FieldKey.COMMENT, FieldKey.TRACK, FieldKey.GENRE)) {
                    val v = runCatching { v1.getFirst(k) }.getOrNull().orEmpty().trim()
                    if (v.isNotEmpty() && tag.getFirst(k).isNullOrEmpty()) runCatching { tag.setField(k, v) }
                }
            }
            return tag
        }
        return af.tagAndConvertOrCreateAndSetDefault ?: throw TagException("「${af.file.name}」的格式不支持写入标签")
    }

    /** Keeps an existing ID3v1 tag in step with the fields edited in ID3v2 (it is never removed or created). */
    private fun syncId3v1(mp3: MP3File, edit: TagEdit) {
        val v1 = mp3.iD3v1Tag ?: return
        for ((field, value) in edit.fields) {
            val key = when (field) {
                TagField.TITLE -> FieldKey.TITLE; TagField.ARTIST -> FieldKey.ARTIST; TagField.ALBUM -> FieldKey.ALBUM
                TagField.YEAR -> FieldKey.YEAR; TagField.COMMENT -> FieldKey.COMMENT; TagField.TRACK -> FieldKey.TRACK
                TagField.GENRE -> FieldKey.GENRE
                else -> continue
            }
            val v = value.trim()
            // ID3v1 is ISO-8859-1 only: a value it cannot hold (e.g. Chinese) would turn into garbage, so leave that field.
            if (v.isNotEmpty() && !Charsets.ISO_8859_1.newEncoder().canEncode(v)) continue
            runCatching { if (v.isEmpty()) v1.deleteField(key) else v1.setField(key, v) } // ID3v1 limits (30 chars, genre list) are best effort
        }
    }

    /**
     * The editor's 注释 is the COMM frame without a description. Other COMM frames (iTunNORM, iTunSMPB, MusicMatch…)
     * are kept, and an existing comment keeps its language code.
     */
    private fun setId3Comment(tag: AbstractID3v2Tag, v: String) {
        val frames = tag.getFields("COMM").filterIsInstance<AbstractID3v2Frame>()
        val main = frames.filter { (it.body as? FrameBodyCOMM)?.description.isNullOrEmpty() }
        if (v.isNotEmpty() && main.isNotEmpty()) { (main.first().body as FrameBodyCOMM).text = v; return }
        if (v.isNotEmpty()) { tag.setField(FieldKey.COMMENT, v); return }
        if (main.isEmpty()) return
        val keep = frames - main.toSet()
        tag.removeFrame("COMM")
        keep.forEach { tag.addField(it) }
    }

    /** Raw picture fields that are not the front cover, to be re-added unchanged after replacing the front cover. */
    private fun otherPictures(tag: Tag): List<org.jaudiotagger.tag.TagField> = try {
        when (tag) {
            is AbstractID3v2Tag -> tag.getFields("APIC").filter { f ->
                val b = (f as? AbstractID3v2Frame)?.body
                b is org.jaudiotagger.tag.id3.framebody.FrameBodyAPIC && b.pictureType != PictureTypes.DEFAULT_ID
            }
            is FlacTag -> tag.images.filter { it.pictureType != PictureTypes.DEFAULT_ID }
            is VorbisCommentTag -> tag.getFields("METADATA_BLOCK_PICTURE").filter { VorbisComments.pictureType(it.toString()) != PictureTypes.DEFAULT_ID }
            else -> emptyList() // MP4 'covr' has no picture types: all images are covers
        }
    } catch (_: Exception) {
        emptyList()
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
