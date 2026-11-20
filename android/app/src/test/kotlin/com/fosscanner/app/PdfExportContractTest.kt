package com.fosscanner.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PdfExportContractTest {
    @Test fun missingDensitiesKeepTheHistoricalDefault() {
        assertEquals(listOf(150, 150), PdfExportContract.pageDpis(null, 2))
    }

    @Test fun acceptsOneValidDensityPerPage() {
        assertEquals(listOf(72, 300), PdfExportContract.pageDpis(listOf(72, 300), 2))
    }

    @Test fun rejectsMalformedDensities() {
        assertNull(PdfExportContract.pageDpis(listOf(150), 2))
        assertNull(PdfExportContract.pageDpis(listOf(150, 0), 2))
        assertNull(PdfExportContract.pageDpis(listOf(150, 2401), 2))
        assertNull(PdfExportContract.pageDpis(listOf(150, "150"), 2))
        assertNull(PdfExportContract.pageDpis(listOf(150.0, 150), 2))
        assertNull(PdfExportContract.pageDpis("150", 1))
    }

    @Test fun savedNamesAreShownAsReportedButSafe() {
        assertEquals("Scan 2026-11-19 14-05.pdf", PdfExportContract.savedName("Scan 2026-11-19 14-05.pdf"))
        assertEquals("My scan (1).pdf", PdfExportContract.savedName("  My\u0000scan\n(1).pdf "))
        assertEquals(255, PdfExportContract.savedName("a".repeat(400))!!.length)
        assertNull(PdfExportContract.savedName(null))
        assertNull(PdfExportContract.savedName(" \u0001 "))
    }
}
