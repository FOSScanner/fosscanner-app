package com.fosscanner.app

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OcrModelStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val bytes = "synthetic model".toByteArray()
    private val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    @Test fun installsAndReusesVerifiedModel() {
        val directory = File(temporary.root, "tessdata")
        OcrModelStore.installVerified(directory, "test.traineddata", hash) { bytes.inputStream() }
        val model = File(directory, "test.traineddata")
        assertArrayEquals(bytes, model.readBytes())
        assertTrue(model.setLastModified(1000))
        OcrModelStore.installVerified(directory, "test.traineddata", hash) { error("Verified model must be reused") }
        assertEquals(1000L, model.lastModified())
        assertEquals(listOf("test.traineddata"), directory.list()!!.toList())
    }

    @Test fun replacesTruncatedAndSameSizeCorruptModels() {
        val directory = temporary.newFolder("tessdata")
        val model = File(directory, "test.traineddata")
        for (corrupt in listOf(byteArrayOf(0), ByteArray(bytes.size))) {
            model.writeBytes(corrupt)
            OcrModelStore.installVerified(directory, model.name, hash) { bytes.inputStream() }
            assertArrayEquals(bytes, model.readBytes())
            assertEquals(listOf(model.name), directory.list()!!.toList())
        }
    }

    @Test fun rejectsBadChecksumWithoutChangingExistingModel() {
        val directory = temporary.newFolder("tessdata")
        val model = File(directory, "test.traineddata")
        val previous = "old model".toByteArray()
        model.writeBytes(previous)
        assertThrows(IllegalArgumentException::class.java) {
            OcrModelStore.installVerified(directory, model.name, hash) { byteArrayOf(0).inputStream() }
        }
        assertArrayEquals(previous, model.readBytes())
        assertEquals(1, directory.list()!!.size)
    }

    @Test fun removesTemporaryFileIfReplacementFails() {
        val directory = temporary.newFolder("tessdata")
        val obstruction = File(directory, "test.traineddata")
        assertTrue(obstruction.mkdir())
        assertThrows(IllegalStateException::class.java) {
            OcrModelStore.installVerified(directory, obstruction.name, hash) { bytes.inputStream() }
        }
        assertEquals(listOf(obstruction.name), directory.list()!!.toList())
    }

    @Test fun closesFailedInputAndPreservesPreviousModel() {
        val directory = temporary.newFolder("tessdata")
        val model = File(directory, "test.traineddata")
        val previous = "old model".toByteArray()
        model.writeBytes(previous)
        var closed = false
        val failing = object : InputStream() {
            override fun read(): Int = throw IOException("Synthetic read failure")
            override fun close() { closed = true }
        }
        assertThrows(IOException::class.java) {
            OcrModelStore.installVerified(directory, model.name, hash) { failing }
        }
        assertTrue(closed)
        assertArrayEquals(previous, model.readBytes())
        assertEquals(listOf(model.name), directory.list()!!.toList())
    }

    @Test fun rejectsUnbundledModelAndPathTraversal() {
        assertThrows(IllegalArgumentException::class.java) {
            OcrModelStore.install(temporary.root) { bytes.inputStream() }
        }
        assertThrows(IllegalArgumentException::class.java) {
            OcrModelStore.installVerified(temporary.root, "../outside", hash) { bytes.inputStream() }
        }
        assertEquals(0, temporary.root.list()!!.size)
    }
}
