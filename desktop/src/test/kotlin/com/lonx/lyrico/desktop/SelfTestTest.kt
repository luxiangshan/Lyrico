package com.lonx.lyrico.desktop

import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertTrue

/** The packaged app's --selftest, run on the build JVM too. */
class SelfTestTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun selfTestPasses() {
        val report = File(tmp.root, "r.txt")
        val ok = SelfTest.run(report)
        assertTrue(ok, report.readText())
    }
}
