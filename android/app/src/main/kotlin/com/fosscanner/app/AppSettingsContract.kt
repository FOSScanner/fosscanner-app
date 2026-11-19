package com.fosscanner.app

/**
 * The app-settings channel, kept free of Android types so it runs as a JVM
 * unit test. Keep in sync with lib/services/app_settings.dart.
 */
internal object AppSettingsContract {
    const val CHANNEL = "com.fosscanner.app/app_settings"
    const val OPEN_METHOD = "openAppSettings"

    /** The `package:` URI ACTION_APPLICATION_DETAILS_SETTINGS expects. */
    fun detailsUri(packageName: String): String {
        require(packageName.isNotBlank() && packageName.none { it.isWhitespace() || it == ':' || it == '/' })
        return "package:$packageName"
    }
}
