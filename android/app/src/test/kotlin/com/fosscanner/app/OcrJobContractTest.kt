package com.fosscanner.app

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class OcrJobContractTest {
    private lateinit var cache: File
    private lateinit var job: File

    @Before fun setUp() {
        cache = Files.createTempDirectory("cache").toFile()
        job = File(cache, "${OcrCacheCleanupCoordinator.JOB_PREFIX}1").apply { mkdirs() }
    }

    @After fun tearDown() {
        cache.deleteRecursively()
    }

    private fun page(index: Int, bytes: Int = 3, directory: File = job): File =
        File(directory, "page_$index.jpg").apply { writeBytes(ByteArray(bytes)) }

    @Test fun acceptsOrderedPagesInsideAJobDirectory() {
        val pages = listOf(page(0), page(1))
        val directory = OcrJobContract.jobDirectory(cache, pages.first())
        assertEquals(job.canonicalFile, directory)
        assertEquals(
            pages.map { it.canonicalFile },
            OcrJobContract.pageImages(directory, pages.map { it.path }, 10, 100),
        )
    }

    @Test fun rejectsFilesOutsideAJobDirectory() {
        val other = File(cache, "elsewhere").apply { mkdirs() }
        assertThrows(IllegalArgumentException::class.java) {
            OcrJobContract.jobDirectory(cache, page(0, directory = other))
        }
        assertThrows(IllegalArgumentException::class.java) {
            OcrJobContract.jobDirectory(cache, File(job, "../../escape.jpg"))
        }
    }

    @Test fun rejectsUnorderedEmptyOrOversizedPages() {
        val directory = job.canonicalFile
        assertThrows(IllegalArgumentException::class.java) {
            OcrJobContract.pageImages(directory, listOf(page(1).path), 10, 100)
        }
        assertThrows(IllegalArgumentException::class.java) {
            OcrJobContract.pageImages(directory, listOf(page(0, bytes = 0).path), 10, 100)
        }
        assertThrows(IllegalArgumentException::class.java) {
            OcrJobContract.pageImages(directory, listOf(page(0, bytes = 11).path), 10, 100)
        }
        assertThrows(IllegalArgumentException::class.java) {
            OcrJobContract.pageImages(directory, listOf(page(0, 6).path, page(1, 6).path), 10, 10)
        }
    }

    @Test fun joinsPageTextsInOrderAndSkipsEmptyPages() {
        assertEquals(
            "First line\nsecond\n\nPage three",
            OcrJobContract.joinPages(listOf("First line\nsecond\n\n", null, "  \n", "\nPage three ")),
        )
        assertEquals("", OcrJobContract.joinPages(listOf(null, "", " \n")))
    }
}
