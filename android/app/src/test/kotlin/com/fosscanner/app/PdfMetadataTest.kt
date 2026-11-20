package com.fosscanner.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PdfMetadataTest {
    @get:Rule
    val folder = TemporaryFolder()

    /** A PDF laid out like Tesseract's renderer output, with a valid xref. */
    private fun tesseractLikePdf(binaryPage: Boolean = true): ByteArray {
        val objects = listOf(
            "1 0 obj\n<<\n  /Type /Catalog\n  /Pages 2 0 R\n>>\nendobj\n",
            "2 0 obj\n<<\n  /Type /Pages\n  /Kids [ 3 0 R ]\n  /Count 1\n>>\nendobj\n",
            "3 0 obj\n<<\n  /Type /Page\n  /Parent 2 0 R\n  /MediaBox [0 0 595.2 841.92]\n" +
                "  /Contents 4 0 R\n>>\nendobj\n",
            // Stream bytes that look like an information dictionary must not
            // be mistaken for one.
            "4 0 obj\n<<\n  /Length 40\n>>\nstream\n" +
                (if (binaryPage) "\u0000ÿ5 0 obj << /Producer (x) >>\u0001endobj" else "q Q") +
                "\nendstream\nendobj\n",
            "5 0 obj\n<<\n  /Producer (Tesseract 5.5.1)\n" +
                "  /CreationDate (D:20261119140512)\n" +
                "  /Title <FEFF0046004F00530053>\n>>\nendobj\n",
        )
        val header = "%PDF-1.5\n%Þ­¾ë\n"
        val body = StringBuilder(header)
        val offsets = mutableListOf<Int>()
        for (obj in objects) {
            offsets += body.length
            body.append(obj)
        }
        val xref = body.length
        body.append("xref\n0 6\n0000000000 65535 f \n")
        for (offset in offsets) body.append(String.format("%010d 00000 n \n", offset))
        body.append("trailer\n<<\n  /Size 6\n  /Root 1 0 R\n  /Info 5 0 R\n>>\n")
        body.append("startxref\n$xref\n%%EOF\n")
        return body.toString().toByteArray(Charsets.ISO_8859_1)
    }

    private fun text(bytes: ByteArray) = String(bytes, Charsets.ISO_8859_1)

    private fun xrefOffsetsPointAtObjects(bytes: ByteArray) {
        val pdf = text(bytes)
        val xref = pdf.substring(pdf.lastIndexOf("xref\n"))
        val offsets = Regex("(\\d{10}) 00000 n").findAll(xref).map { it.groupValues[1].toInt() }.toList()
        offsets.forEachIndexed { index, offset ->
            assertTrue(pdf.startsWith("${index + 1} 0 obj", offset))
        }
    }

    @Test
    fun blanksProducerDateTitleAndTheTrailerReference() {
        val pdf = tesseractLikePdf()
        val original = pdf.copyOf()
        assertTrue(PdfMetadata.blankInfoDictionary(pdf))

        val result = text(pdf)
        assertEquals(original.size, pdf.size)
        assertFalse(result.contains("Tesseract"))
        assertFalse(result.contains("/CreationDate"))
        assertFalse(result.contains("/Title"))
        assertFalse(result.substring(result.lastIndexOf("trailer")).contains("/Info"))
        assertTrue(result.contains("/Root 1 0 R"))
        assertTrue(Regex("5 0 obj\n<<\\s*>>\nendobj").containsMatchIn(result))
        // The page stream, including its look-alike bytes, is untouched.
        val stream = text(original).indexOf("stream\n")
        assertArrayEquals(
            original.copyOfRange(0, stream + 60),
            pdf.copyOfRange(0, stream + 60),
        )
        xrefOffsetsPointAtObjects(pdf)
    }

    @Test
    fun aDocumentWithoutInformationIsLeftAlone() {
        val pdf = text(tesseractLikePdf()).replace("  /Info 5 0 R\n", "").toByteArray(Charsets.ISO_8859_1)
        val copy = pdf.copyOf()
        assertFalse(PdfMetadata.blankInfoDictionary(pdf))
        assertArrayEquals(copy, pdf)
    }

    @Test
    fun unexpectedStructuresAreLeftAlone() {
        for (broken in listOf(
            // Nested dictionary inside the information object.
            text(tesseractLikePdf()).replace("/Title <FEFF0046004F00530053>", "/X << /Y 1 >>"),
            // Referenced object missing.
            text(tesseractLikePdf()).replace("/Info 5 0 R", "/Info 9 0 R"),
            // No trailer.
            text(tesseractLikePdf()).replace("trailer", "xxxxxxx"),
        )) {
            val pdf = broken.toByteArray(Charsets.ISO_8859_1)
            val copy = pdf.copyOf()
            assertFalse(PdfMetadata.blankInfoDictionary(pdf))
            assertArrayEquals(copy, pdf)
        }
    }

    @Test
    fun rewritesOnlyTheEndOfAFileInPlace() {
        val file = folder.newFile("document.pdf")
        val pdf = tesseractLikePdf(binaryPage = false)
        file.writeBytes(pdf)
        assertTrue(PdfMetadata.blankInfoDictionary(file))
        val result = file.readBytes()
        assertEquals(pdf.size, result.size)
        assertFalse(text(result).contains("Tesseract"))
        xrefOffsetsPointAtObjects(result)
        // A second pass finds nothing left to remove.
        assertFalse(PdfMetadata.blankInfoDictionary(file))
    }
}
