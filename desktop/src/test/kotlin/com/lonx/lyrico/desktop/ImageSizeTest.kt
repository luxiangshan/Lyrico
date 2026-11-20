package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.tag.ImageSize
import org.junit.Test
import kotlin.test.assertEquals

class ImageSizeTest {
    private fun res(n: String) = javaClass.getResourceAsStream("/audio/$n")!!.readBytes()

    @Test
    fun headers() {
        val png = ImageSize.of(res("cover.png"))
        val webp = ImageSize.of(res("cover.webp"))
        val jpg = ImageSize.of(res("cover.jpg"))
        val ref = javax.imageio.ImageIO.read(res("cover.png").inputStream()).let { it.width to it.height }
        assertEquals(ref, png)
        assertEquals(ref, webp) // the webp was made from cover.png
        assertEquals(javax.imageio.ImageIO.read(res("cover.jpg").inputStream()).let { it.width to it.height }, jpg)
    }
}
