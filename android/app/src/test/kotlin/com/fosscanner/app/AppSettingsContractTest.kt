package com.fosscanner.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AppSettingsContractTest {
    @Test fun matchesTheDartChannel() {
        assertEquals("com.fosscanner.app/app_settings", AppSettingsContract.CHANNEL)
        assertEquals("openAppSettings", AppSettingsContract.OPEN_METHOD)
        assertEquals("shouldShowCameraRationale", AppSettingsContract.CAMERA_RATIONALE_METHOD)
    }

    @Test fun pointsTheDetailsPageAtThisPackage() {
        assertEquals("package:com.fosscanner.app", AppSettingsContract.detailsUri("com.fosscanner.app"))
    }

    @Test fun rejectsMalformedPackageNames() {
        for (name in listOf("", " ", "a/b", "a:b")) {
            assertThrows(IllegalArgumentException::class.java) { AppSettingsContract.detailsUri(name) }
        }
    }
}
