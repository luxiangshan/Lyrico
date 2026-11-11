package com.lonx.lyrico.remote.integration

import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/** Lyrico Mod: save / share the 115 login QR code so it can be scanned from the album or another phone. */
object QrImageExport {
    private const val ALBUM_DIR = "LyricoMod"
    private const val EXPORT_SIZE = 720

    /** True when [saveToGallery] can write without a runtime permission (API 29+ scoped MediaStore). */
    val canSaveWithoutPermission: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /**
     * Inserts the QR image into Pictures/LyricoMod via MediaStore. API 29+ only (no permission needed);
     * callers fall back to [share] on API 28. Blocking; call off the main thread.
     */
    fun saveToGallery(context: Context, content: String) {
        if (!canSaveWithoutPermission) throw IOException("MediaStore RELATIVE_PATH needs Android 10+")
        val bitmap = QrCodeBitmap.encode(content, EXPORT_SIZE)
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "115-login-qr-${System.currentTimeMillis()}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$ALBUM_DIR")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("MediaStore insert failed")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) throw IOException("PNG encode failed")
            } ?: throw IOException("Cannot open $uri")
            resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw e
        } finally {
            bitmap.recycle()
        }
    }

    /** Writes the QR to the cache and returns a share-sheet chooser intent (FileProvider uri). Blocking. */
    fun shareIntent(context: Context, content: String, chooserTitle: String): Intent {
        val dir = File(context.cacheDir, "qr").apply { mkdirs() }
        val file = File(dir, "115-login-qr.png")
        val bitmap = QrCodeBitmap.encode(content, EXPORT_SIZE)
        try {
            file.outputStream().use { out -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, out) }
        } finally {
            bitmap.recycle()
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(null, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return Intent.createChooser(send, chooserTitle).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}
