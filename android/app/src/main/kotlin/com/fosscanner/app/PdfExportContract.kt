package com.fosscanner.app

/**
 * Pure checks for the PDF export channel calls, kept free of Android types so
 * they run as JVM unit tests. Keep in sync with lib/services/ocr_service.dart.
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

}
