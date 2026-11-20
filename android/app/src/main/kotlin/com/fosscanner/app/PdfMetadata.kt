package com.fosscanner.app

import java.io.File
import java.io.RandomAccessFile

/**
 * Removes the document information dictionary Tesseract's PDF renderer
 * writes (`/Producer (Tesseract x.y.z)`, `/CreationDate`, `/Title`), so
 * searchable exports carry the same minimal metadata as image-only ones,
 * which have no information dictionary at all.
 *
 * The bytes are blanked in place with spaces: every object keeps its offset,
 * so the cross-reference table stays valid without rewriting the file. The
 * emptied object remains as an unreferenced `<< >>` dictionary. Pure and free
 * of Android types so it runs as a JVM unit test.
 */
internal object PdfMetadata {
    /** Tesseract writes the information dictionary just before the xref. */
    const val TAIL_BYTES = 1024 * 1024

    private val trailerInfo = Regex("/Info\\s+(\\d+)\\s+(\\d+)\\s+R")

    /**
     * Blanks the information dictionary referenced by the last trailer in
     * [tail] (the end of a PDF), and the trailer's reference to it. Returns
     * false, leaving [tail] untouched, when there is nothing to remove or the
     * structure is not the simple one Tesseract writes.
     */
    fun blankInfoDictionary(tail: ByteArray): Boolean {
        // ISO-8859-1 maps each byte to one char, so indices are byte offsets.
        val text = String(tail, Charsets.ISO_8859_1)
        val trailer = text.lastIndexOf("trailer")
        if (trailer < 0) return false
        val reference = trailerInfo.find(text, trailer) ?: return false
        val trailerEnd = text.indexOf("startxref", trailer)
        if (trailerEnd in 0 until reference.range.first) return false
        val (number, generation) = reference.destructured
        val header = Regex("(?:^|[\\r\\n])$number\\s+$generation\\s+obj\\b")
        val objectStart = header.findAll(text.substring(0, trailer)).lastOrNull()
            ?: return false
        val objectEnd = text.indexOf("endobj", objectStart.range.last)
        if (objectEnd < 0 || objectEnd > trailer) return false
        val open = text.indexOf("<<", objectStart.range.last)
        val close = text.lastIndexOf(">>", objectEnd)
        if (open < 0 || close < open + 2) return false
        // Only plain-text dictionaries: no nested dictionaries or streams.
        val body = text.substring(open + 2, close)
        if (body.contains("<<") || body.contains("stream") ||
            body.any { it.code !in 0x09..0x7e }
        ) {
            return false
        }
        blank(tail, open + 2, close)
        blank(tail, reference.range.first, reference.range.last + 1)
        return true
    }

    /** Applies [blankInfoDictionary] to the end of [file] in place. */
    fun blankInfoDictionary(file: File): Boolean {
        RandomAccessFile(file, "rw").use { pdf ->
            val length = pdf.length()
            val size = minOf(length, TAIL_BYTES.toLong()).toInt()
            val tail = ByteArray(size)
            pdf.seek(length - size)
            pdf.readFully(tail)
            if (!blankInfoDictionary(tail)) return false
            pdf.seek(length - size)
            pdf.write(tail)
            return true
        }
    }

    private fun blank(bytes: ByteArray, from: Int, to: Int) {
        for (index in from until to) {
            val byte = bytes[index]
            // Keep line breaks so the file stays readable in a text editor.
            if (byte != '\n'.code.toByte() && byte != '\r'.code.toByte()) {
                bytes[index] = ' '.code.toByte()
            }
        }
    }
}
