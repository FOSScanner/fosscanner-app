package com.fosscanner.app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PdfPageImportTest {
    @get:Rule val temporary = TemporaryFolder()

    private val a4 = 595 to 842

    private fun request(
        dpi: Int = 300,
        maxPages: Int = 100,
        maxPagePixels: Long = PdfPageImport.MAX_PIXELS,
        maxTotalBytes: Long = 256L * 1024 * 1024,
    ) = PdfImportRequest(dpi, maxPages, maxPagePixels, maxTotalBytes, jpegQuality = 90)

    @Test fun sizesPagesFromPointsAndDpi() {
        assertEquals(PixelSize(2479, 3508), PdfPageImport.renderSize(595, 842, 300, PdfPageImport.MAX_PIXELS))
        assertEquals(PixelSize(1239, 1754), PdfPageImport.renderSize(595, 842, 150, PdfPageImport.MAX_PIXELS))
        assertEquals(PixelSize(72, 72), PdfPageImport.renderSize(72, 72, 72, PdfPageImport.MAX_PIXELS))
    }

    @Test fun capsTheLongEdgeAndPixelCount() {
        // A 2 m banner at 300 DPI would be far past the 8192 px edge.
        val banner = PdfPageImport.renderSize(5669, 595, 300, PdfPageImport.MAX_PIXELS)!!
        assertEquals(8192, banner.width)
        assertTrue(banner.height in 858..860)

        val poster = PdfPageImport.renderSize(2384, 3370, 300, PdfPageImport.MAX_PIXELS)!!
        assertTrue(poster.width <= 8192 && poster.height <= 8192)
        assertTrue(poster.width.toLong() * poster.height <= PdfPageImport.MAX_PIXELS)
        // Aspect ratio is kept within rounding.
        assertEquals(2384.0 / 3370.0, poster.width.toDouble() / poster.height, 0.002)

        val budget = PdfPageImport.renderSize(595, 842, 300, maxPixels = 1_000_000)!!
        assertTrue(budget.width.toLong() * budget.height <= 1_000_000)
        assertTrue(budget.width.toLong() * budget.height > 990_000)

        // The request can never raise the absolute pixel limit.
        val huge = PdfPageImport.renderSize(2384, 3370, 600, maxPixels = Long.MAX_VALUE)!!
        assertTrue(huge.width.toLong() * huge.height <= PdfPageImport.MAX_PIXELS)
    }

    @Test fun rejectsUnusablePageSizes() {
        assertNull(PdfPageImport.renderSize(0, 842, 300, PdfPageImport.MAX_PIXELS))
        assertNull(PdfPageImport.renderSize(595, -1, 300, PdfPageImport.MAX_PIXELS))
        assertNull(PdfPageImport.renderSize(595, 842, 300, maxPixels = 0))
        // Rounds below the 3 px minimum edge.
        assertNull(PdfPageImport.renderSize(1, 1, 72, PdfPageImport.MAX_PIXELS))
        assertNull(PdfPageImport.renderSize(10000, 1, 72, PdfPageImport.MAX_PIXELS))
    }

    @Test fun pageLimitNeverExceedsTheDocument() {
        assertEquals(3, PdfPageImport.pageLimit(3, 100))
        assertEquals(2, PdfPageImport.pageLimit(10, 2))
        assertEquals(100, PdfPageImport.pageLimit(500, 1000))
        assertEquals(0, PdfPageImport.pageLimit(0, 5))
        assertEquals(0, PdfPageImport.pageLimit(5, -1))
    }

    @Test fun parsesAndValidatesRequests() {
        val parsed = PdfImportRequest.parse(300, 99, 30_000_000L, 1024, 90)!!
        assertEquals(300, parsed.dpi)
        assertEquals(99, parsed.maxPages)
        assertEquals(PdfPageImport.MAX_PIXELS, parsed.maxPagePixels)
        assertEquals(1024L, parsed.maxTotalBytes)
        assertNull(PdfImportRequest.parse(null, 1, 100, 1, 90))
        assertNull(PdfImportRequest.parse("300", 1, 100, 1, 90))
        assertNull(PdfImportRequest.parse(10, 1, 100, 1, 90))
        assertNull(PdfImportRequest.parse(2000, 1, 100, 1, 90))
        assertNull(PdfImportRequest.parse(300, 0, 100, 1, 90))
        assertNull(PdfImportRequest.parse(300, 101, 100, 1, 90))
        assertNull(PdfImportRequest.parse(300, 1, 8, 1, 90))
        assertNull(PdfImportRequest.parse(300, 1, 100, 0, 90))
        assertNull(PdfImportRequest.parse(300, 1, 100, 1, 0))
    }

    private fun writer(bytesPerPage: (Int) -> Int = { 10 }, rendered: MutableList<Pair<Int, PixelSize>>? = null) =
        { index: Int, size: PixelSize, target: File ->
            rendered?.add(index to size)
            target.writeBytes(ByteArray(bytesPerPage(index)))
        }

    @Test fun rendersEveryPageInOrderWithProgress() {
        val directory = File(temporary.root, "pdf")
        val rendered = mutableListOf<Pair<Int, PixelSize>>()
        val progress = mutableListOf<Pair<Int, Int>>()
        val result = PdfPageImport.renderPages(
            directory, 3, request(dpi = 72),
            pageSize = { a4 },
            render = writer(rendered = rendered),
            isCancelled = { false },
            onProgress = { done, total -> progress.add(done to total) },
        )
        assertEquals(listOf(0, 1, 2), rendered.map { it.first })
        assertEquals(PixelSize(595, 842), rendered.first().second)
        assertEquals(3, result.paths.size)
        assertTrue(result.paths.all { File(it).parentFile == directory && File(it).isFile })
        assertEquals(listOf(0 to 3, 1 to 3, 2 to 3, 3 to 3), progress)
        assertFalse(result.truncated)
        assertEquals(
            mapOf("paths" to result.paths, "pageCount" to 3, "rejected" to 0, "truncated" to false),
            result.toChannelMap(),
        )
    }

    @Test fun stopsAtThePageLimitWithoutRenderingTheRest() {
        val rendered = mutableListOf<Pair<Int, PixelSize>>()
        val result = PdfPageImport.renderPages(
            temporary.newFolder(), 10, request(maxPages = 2),
            pageSize = { a4 }, render = writer(rendered = rendered),
            isCancelled = { false }, onProgress = { _, _ -> },
        )
        assertEquals(2, rendered.size)
        assertEquals(2, result.paths.size)
        assertEquals(10, result.pageCount)
        assertTrue(result.truncated)
    }

    @Test fun stopsBeforeRenderingOnceTheMemoryBudgetIsUsed() {
        val rendered = mutableListOf<Pair<Int, PixelSize>>()
        val result = PdfPageImport.renderPages(
            temporary.newFolder(), 5, request(maxTotalBytes = 20),
            pageSize = { a4 }, render = writer(rendered = rendered),
            isCancelled = { false }, onProgress = { _, _ -> },
        )
        // Two 10-byte pages use the budget; the third is never rendered.
        assertEquals(2, rendered.size)
        assertEquals(2, result.paths.size)
        assertTrue(result.truncated)
    }

    @Test fun dropsAPageThatOverflowsTheBudgetAndStops() {
        val directory = temporary.newFolder()
        val result = PdfPageImport.renderPages(
            directory, 3, request(maxTotalBytes = 25),
            pageSize = { a4 }, render = writer(bytesPerPage = { 20 }),
            isCancelled = { false }, onProgress = { _, _ -> },
        )
        assertEquals(1, result.paths.size)
        assertTrue(result.truncated)
        assertEquals(1, directory.listFiles()!!.size)
    }

    @Test fun rejectsEmptyAndUnsizablePagesButContinues() {
        val result = PdfPageImport.renderPages(
            temporary.newFolder(), 3, request(),
            pageSize = { index -> if (index == 1) 0 to 0 else a4 },
            render = writer(bytesPerPage = { if (it == 2) 0 else 10 }),
            isCancelled = { false }, onProgress = { _, _ -> },
        )
        assertEquals(1, result.paths.size)
        assertEquals(2, result.rejected)
        assertFalse(result.truncated)
    }

    @Test fun cancellationDeletesEveryRenderedPage() {
        val directory = temporary.newFolder()
        var cancelled = false
        try {
            PdfPageImport.renderPages(
                directory, 5, request(),
                pageSize = { a4 },
                render = { index, size, target ->
                    writer()(index, size, target)
                    if (index == 1) cancelled = true
                },
                isCancelled = { cancelled }, onProgress = { _, _ -> },
            )
            fail("Expected cancellation")
        } catch (_: PdfImportCancelledException) {
        }
        assertEquals(0, directory.listFiles()!!.size)
    }

    @Test fun renderFailureDeletesEveryRenderedPage() {
        val directory = temporary.newFolder()
        try {
            PdfPageImport.renderPages(
                directory, 3, request(),
                pageSize = { a4 },
                render = { index, size, target ->
                    writer()(index, size, target)
                    if (index == 2) throw IllegalStateException("corrupt page")
                },
                isCancelled = { false }, onProgress = { _, _ -> },
            )
            fail("Expected failure")
        } catch (_: IllegalStateException) {
        }
        assertEquals(0, directory.listFiles()!!.size)
    }

    @Test fun anEmptyPdfIsUnreadable() {
        try {
            PdfPageImport.renderPages(
                temporary.newFolder(), 0, request(),
                pageSize = { a4 }, render = writer(),
                isCancelled = { false }, onProgress = { _, _ -> },
            )
            fail("Expected an unreadable PDF")
        } catch (_: PdfUnreadableException) {
        }
    }

    @Test fun clearDirectoryRemovesLeftovers() {
        val directory = temporary.newFolder()
        File(directory, "page_0.jpg").writeText("x")
        PdfPageImport.clearDirectory(directory)
        assertEquals(0, directory.listFiles()!!.size)
        PdfPageImport.clearDirectory(File(temporary.root, "missing"))
    }
}
