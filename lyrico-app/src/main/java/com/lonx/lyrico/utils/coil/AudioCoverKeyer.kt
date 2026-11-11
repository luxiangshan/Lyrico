package com.lonx.lyrico.utils.coil

import coil3.key.Keyer
import coil3.request.Options
import com.lonx.lyrico.data.model.artwork.CoverRequest

/**
 * [remoteCoverState] (Lyrico Mod) tells whether the remote cover disk cache already holds an entry for a
 * remote song; it is part of the key so an item rendered before its cover was cached is re-requested.
 */
class AudioCoverKeyer(
    private val remoteCoverState: ((CoverRequest) -> Boolean)? = null,
): Keyer<CoverRequest> {
    override fun key(data: CoverRequest, options: Options): String {
        // 提取文件路径作为主键，结合时间戳生成唯一缓存键
        val path = data.uri.path ?: data.uri.toString()
        return CoverRequest.getCacheKey(
            path = path,
            timestamp = data.lastUpdate,
            pictureType = data.pictureType,
            fallbackPictureTypes = data.fallbackPictureTypes,
            fallbackToAny = data.fallbackToAny,
            candidates = data.candidates,
            skipEmbeddedPictures = data.skipEmbeddedPictures
        ) + "@external:" + listOf(data.artistName, data.artistPosterFolders, data.artistPosterRevision).toString() +
            (if (data.artistName != null) "@artist-source:2" else "") +
            (if (data.uri.scheme == "remote") "@size:${data.fileSize}@rc:${remoteCoverState?.invoke(data) ?: false}" else "")
    }
}
