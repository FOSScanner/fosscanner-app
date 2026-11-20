package com.fosscanner.app

import java.io.File

/**
 * Pure checks for the OCR job channel calls (searchable PDF and text copy),
 * kept free of Android types so they run as JVM unit tests. Keep in sync with
 * lib/services/ocr_service.dart.
 */
internal object OcrJobContract {
    /**
     * Clip description extra that keyboards and the clipboard preview honour
     * to hide content. It is `ClipDescription.EXTRA_IS_SENSITIVE` on Android
     * 13+, and the documented literal for older releases.
     */
    const val SENSITIVE_CLIP_EXTRA = "android.content.extra.IS_SENSITIVE"

    /**
     * The canonical `fosscanner_ocr_*` job directory of [cacheDir] that
     * directly contains [file], or throws [IllegalArgumentException].
     */
    fun jobDirectory(cacheDir: File, file: File): File {
        val directory = requireNotNull(file.canonicalFile.parentFile)
        require(
            directory.parentFile == cacheDir.canonicalFile &&
                directory.name.startsWith(OcrCacheCleanupCoordinator.JOB_PREFIX) &&
                directory.isDirectory,
        )
        return directory
    }

    /**
     * The page images Dart wrote into [jobDirectory], in order, after checking
     * they are exactly `page_0.jpg`, `page_1.jpg`, ... with bounded sizes, so
     * the channel cannot be pointed at arbitrary files. Throws
     * [IllegalArgumentException] otherwise.
     */
    fun pageImages(
        jobDirectory: File,
        imagePaths: List<String>,
        maxImageBytes: Long,
        maxDocumentBytes: Long,
    ): List<File> {
        val images = imagePaths.map { File(it).canonicalFile }
        var encodedBytes = 0L
        for ((index, image) in images.withIndex()) {
            require(image.parentFile == jobDirectory && image.name == "page_$index.jpg")
            require(image.isFile && image.length() in 1..maxImageBytes)
            encodedBytes += image.length()
            require(encodedBytes <= maxDocumentBytes)
        }
        return images
    }

    /**
     * Joins recognized page texts in page order with one blank line between
     * pages. Trailing whitespace is trimmed and pages without text are
     * skipped, so an empty result means nothing was recognized.
     */
    fun joinPages(pages: List<String?>): String =
        pages.mapNotNull { text -> text?.trimEnd()?.trimStart('\n', '\r')?.takeIf { it.isNotBlank() } }
            .joinToString("\n\n")
}
