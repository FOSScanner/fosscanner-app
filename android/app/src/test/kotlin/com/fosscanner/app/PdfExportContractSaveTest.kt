package com.fosscanner.app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PdfExportContractSaveTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun acceptsOnlyFinishedExportsInsideTheCache() {
        val cache = temporary.newFolder("cache")
        val export = File(cache, "fosscanner_export_123").also { it.mkdir() }
        val pdf = File(export, "Scan 2026-11-19 14-05.pdf").also { it.writeText("%PDF-") }
        assertEquals(pdf.canonicalFile, PdfExportContract.exportFile(cache, pdf.path))
        assertEquals(
            pdf.canonicalFile,
            PdfExportContract.exportFile(cache, "${export.path}/../${export.name}/${pdf.name}"),
        )

        val empty = File(export, "empty.pdf").also { it.writeText("") }
        val notPdf = File(export, "page_0.jpg").also { it.writeText("x") }
        val ocrJob = File(cache, "fosscanner_ocr_1").also { it.mkdir() }
        val ocrPdf = File(ocrJob, "document.pdf").also { it.writeText("%PDF-") }
        val outside = temporary.newFile("outside.pdf").also { it.writeText("%PDF-") }
        val nested = File(export, "fosscanner_export_inner").also { it.mkdir() }
        val nestedPdf = File(nested, "a.pdf").also { it.writeText("%PDF-") }
        for (path in listOf(null, "", empty.path, notPdf.path, ocrPdf.path, outside.path, nestedPdf.path, "${export.path}/missing.pdf")) {
            assertNull(path, PdfExportContract.exportFile(cache, path))
        }
    }

    @Test fun documentTitlesAreSafeSingleNames() {
        assertEquals("Scan 2026-11-19 14-05.pdf", PdfExportContract.documentTitle("Scan 2026-11-19 14-05.pdf"))
        assertEquals("a b c.pdf", PdfExportContract.documentTitle("a/b\\c"))
        assertEquals("etc passwd.pdf", PdfExportContract.documentTitle("../../etc/passwd"))
        assertEquals("x y.pdf", PdfExportContract.documentTitle("x\u0000\ny.PDF"))
        assertEquals("Scan.pdf", PdfExportContract.documentTitle(null))
        assertEquals("Scan.pdf", PdfExportContract.documentTitle(" .pdf "))
        assertEquals("x".repeat(100) + ".pdf", PdfExportContract.documentTitle("x".repeat(300)))
    }
}
