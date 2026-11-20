package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.plugin.MatchScore
import org.junit.Test
import kotlin.test.assertTrue

class MatchScoreTest {
    @Test
    fun ranksExactAboveCovers() {
        val exact = MatchScore.song("晴天", "周杰伦", 269, "晴天", "周杰伦", 269_000)
        val cover = MatchScore.song("晴天", "周杰伦", 269, "晴天 (原唱 周杰伦)", "RyaVocal", 200_000)
        val other = MatchScore.song("晴天", "周杰伦", 269, "七里香", "周杰伦", 299_000)
        assertTrue(exact > 0.95, "$exact")
        assertTrue(exact > cover && cover > other, "$exact $cover $other")
        assertTrue(other < 0.55, "$other")
    }
}
