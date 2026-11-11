package com.lonx.lyrico.remote.integration

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.system.ErrnoException
import android.system.OsConstants
import android.util.Log
import java.io.IOException

/**
 * A read-only file descriptor backed by a [RemoteBlockReader] through
 * [StorageManager.openProxyFileDescriptor]: TagLib (or anything else reading the fd) only pulls the byte
 * ranges it actually touches over the network, instead of the whole file being downloaded first.
 *
 * Each descriptor gets its own [HandlerThread] (the callbacks block on network I/O, so descriptors must
 * not share a thread); the thread quits when the last dup of the descriptor is closed.
 */
object RemoteProxyFd {
    private const val TAG = "RemoteProxyFd"

    @Throws(IOException::class)
    fun open(context: Context, reader: RemoteBlockReader, label: String): ParcelFileDescriptor {
        val storageManager = context.getSystemService(StorageManager::class.java)
            ?: throw IOException("StorageManager unavailable")
        val thread = HandlerThread("remote-fd-${label.takeLast(24)}").apply { start() }
        val callback = object : ProxyFileDescriptorCallback() {
            override fun onGetSize(): Long = reader.size

            override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
                try {
                    return reader.read(offset, data, 0, minOf(size, data.size))
                } catch (e: Exception) {
                    Log.w(TAG, "Remote read failed at $offset (+$size) of $label: ${e.message}")
                    throw ErrnoException("onRead", OsConstants.EIO)
                }
            }

            override fun onRelease() {
                thread.quitSafely()
            }
        }
        return try {
            storageManager.openProxyFileDescriptor(
                ParcelFileDescriptor.MODE_READ_ONLY,
                callback,
                Handler(thread.looper)
            )
        } catch (e: Exception) {
            thread.quitSafely()
            throw if (e is IOException) e else IOException("openProxyFileDescriptor failed: ${e.message}", e)
        }
    }
}
