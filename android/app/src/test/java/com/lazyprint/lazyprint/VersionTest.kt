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
    fun thePackageIsTheOneOfTheOtherPlatforms() {
        assertEquals("com.lazyprint.lazyprint", BuildConfig.APPLICATION_ID.removeSuffix(".debug"))
    }
}
