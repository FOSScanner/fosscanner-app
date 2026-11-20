package com.fosscanner.app

import java.io.File

/**
 * Pure checks for the PDF export channel calls, kept free of Android types so
 * they run as JVM unit tests. Keep in sync with lib/services/ocr_service.dart,
 * lib/services/pdf_export_files.dart and lib/services/pdf_document_saver.dart.
 */
internal object PdfExportContract {
    /** Density Tesseract assumes when Dart sends none (page = pixels / DPI). */
    const val DEFAULT_OCR_DPI = 150

    // Tesseract uses any positive user_defined_dpi but only trusts this range;
    // the Dart planner never asks for more than the source fit density.
    private const val MAX_OCR_DPI = 2400

    /**
     * Per-page OCR densities, or null when [raw] is malformed. A missing list
     * keeps the historical fixed density for every page.
     */
    fun pageDpis(raw: Any?, pageCount: Int): List<Int>? {
        if (raw == null) return List(pageCount) { DEFAULT_OCR_DPI }
        if (raw !is List<*> || raw.size != pageCount) return null
        return raw.map { value ->
            if (value !is Int || value !in 1..MAX_OCR_DPI) return null
            value
        }
    }

    /** Prefix of the per-export cache directories (pdf_export_files.dart). */
    const val EXPORT_PREFIX = "fosscanner_export_"

    const val MAX_DOCUMENT_BYTES = 256L * 1024 * 1024

    private const val MAX_TITLE_LENGTH = 100
    private val forbiddenTitleCharacters = Regex("[\\u0000-\\u001f\\u007f/\\\\:*?\"<>|]")
    private val whitespace = Regex("\\s+")

    /**
     * The exported PDF at [path] if it is one this app wrote for export:
     * a non-empty `.pdf` directly inside a `fosscanner_export_*` directory of
     * [cacheDir]. Anything else (another app's path, a traversal, the OCR
     * job files) is rejected so the channel cannot copy arbitrary files.
     */
    fun exportFile(cacheDir: File, path: String?): File? {
        if (path.isNullOrEmpty()) return null
        return try {
            val file = File(path).canonicalFile
            val directory = file.parentFile ?: return null
            val valid = directory.parentFile == cacheDir.canonicalFile &&
                directory.name.startsWith(EXPORT_PREFIX) &&
                file.name.endsWith(".pdf") &&
                file.isFile &&
                file.length() in 1..MAX_DOCUMENT_BYTES
            if (valid) file else null
        } catch (_: Exception) {
            null
        }
    }

    /**
     * A safe suggested file name for the system picker: no path separators
     * or control characters, bounded length, always ending in `.pdf`.
     */
    fun documentTitle(name: String?): String {
        var base = (name ?: "")
            .replace(forbiddenTitleCharacters, " ")
            .replace(whitespace, " ")
            .trim()
        if (base.endsWith(".pdf", ignoreCase = true)) base = base.dropLast(4)
        // Leading dots would hide the file on many systems.
        base = base.trimStart { it == '.' || it.isWhitespace() }.trim()
        if (base.isEmpty()) base = "Scan"
        return base.take(MAX_TITLE_LENGTH).trim() + ".pdf"
    }
}
