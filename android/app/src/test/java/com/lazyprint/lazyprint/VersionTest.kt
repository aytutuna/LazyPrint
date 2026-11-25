package com.lazyprint.lazyprint

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class VersionTest {
    @Test
    fun theVersionIsTheWindowsVersion() {
        val props = File("../../windows/Directory.Build.props").readText()
        val windows = Regex("<Version>([^<]+)</Version>").find(props)!!.groupValues[1]
        assertEquals(windows, BuildConfig.VERSION_NAME.removeSuffix("-debug"))
    }

    @Test
    fun theAppleVersionsAreTheWindowsVersion() {
        val props = File("../../windows/Directory.Build.props").readText()
        val windows = Regex("<Version>([^<]+)</Version>").find(props)!!.groupValues[1]
        for (spec in listOf("ios", "mac")) {
            val yml = File("../../$spec/project.yml").readText()
            val apple = Regex("MARKETING_VERSION: \"([^\"]+)\"").find(yml)!!.groupValues[1]
            assertEquals(spec, windows, apple)
        }
    }

    @Test
    fun thePackageIsTheOneOfTheOtherPlatforms() {
        assertEquals("com.lazyprint.lazyprint", BuildConfig.APPLICATION_ID.removeSuffix(".debug"))
    }
}
