package com.fosscanner.app

import java.io.File
import java.io.IOException
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** The user cancelled a running PDF import. */
internal class PdfImportCancelledException : Exception()

/** The PDF is password-protected, corrupt, empty, or otherwise unreadable. */
internal class PdfUnreadableException : Exception()

/**
 * Limits for one PDF import, chosen by Dart from the current quality preset
 * and what the document can still hold.
 *
 * Keep the channel contract synchronized with
 * lib/services/pdf_page_importer.dart.
 */
internal data class PdfImportRequest(
    /** Render density; PDF page sizes are in points (1/72 inch). */
    val dpi: Int,
    /** Pages the document can still accept. */
    val maxPages: Int,
    /** Largest bitmap Dart can still process, in pixels. */
    val maxPagePixels: Long,
    /** Encoded bytes the document can still retain, across all pages. */
    val maxTotalBytes: Long,
    val jpegQuality: Int,
) {
    companion object {
        const val MIN_DPI = 72
        const val MAX_DPI = 600

        /** Validates raw channel arguments; null when any is missing or out of range. */
        fun parse(
            dpi: Any?,
            maxPages: Any?,
            maxPagePixels: Any?,
            maxTotalBytes: Any?,
            jpegQuality: Any?,
        ): PdfImportRequest? {
            val density = (dpi as? Number)?.toInt() ?: return null
            val pages = (maxPages as? Number)?.toInt() ?: return null
            val pixels = (maxPagePixels as? Number)?.toLong() ?: return null
            val bytes = (maxTotalBytes as? Number)?.toLong() ?: return null
            val quality = (jpegQuality as? Number)?.toInt() ?: return null
            if (density !in MIN_DPI..MAX_DPI) return null
            if (pages !in 1..PdfPageImport.MAX_PAGES) return null
            if (pixels < PdfPageImport.MIN_EDGE.toLong() * PdfPageImport.MIN_EDGE) return null
            if (bytes <= 0) return null
            if (quality !in 1..100) return null
            return PdfImportRequest(
                dpi = density,
                maxPages = pages,
                maxPagePixels = min(pixels, PdfPageImport.MAX_PIXELS),
                maxTotalBytes = bytes,
                jpegQuality = quality,
            )
        }
    }
}

internal data class PixelSize(val width: Int, val height: Int)

/** What one import hands to Dart. */
internal data class PdfImportResult(
    /** App-owned cache files, in page order; Dart deletes each after reading. */
    val paths: List<String>,
    /** Pages in the PDF. */
    val pageCount: Int,
    /** Pages that could not be rendered within the per-image limits. */
    val rejected: Int,
    /** Rendering stopped early at the page or document memory limit. */
    val truncated: Boolean,
    /**
     * Some added page was rendered below the requested density because the
     * document's processing memory capped its pixels.
     */
    val reduced: Boolean = false,
) {
    fun toChannelMap(): Map<String, Any> = mapOf(
        "paths" to paths,
        "pageCount" to pageCount,
        "rejected" to rejected,
        "truncated" to truncated,
        "reduced" to reduced,
    )
}

/**
 * Rasterizes PDF pages for import, kept free of Android types so sizing,
 * limits and cleanup run as plain JVM unit tests. MainActivity supplies the
 * PdfRenderer-backed callbacks.
 */
internal object PdfPageImport {
    const val DIRECTORY_NAME = "fosscanner_pdf_import"

    // Mirror lib/services/image_metadata.dart's source and document limits.
    const val MAX_EDGE = 8192
    const val MAX_PIXELS = 20_000_000L
    const val MIN_EDGE = 3
    const val MAX_PAGES = 100
    const val MAX_IMAGE_BYTES = 32L * 1024 * 1024

    /** Largest PDF copied into the cache for rendering. */
    const val MAX_PDF_BYTES = 256L * 1024 * 1024

    /**
     * Bitmap size for a page of [widthPoints] x [heightPoints] at [dpi],
     * scaled down uniformly to fit [MAX_EDGE] and [maxPixels]. Null when the
     * page has no usable size.
     */
    fun renderSize(widthPoints: Int, heightPoints: Int, dpi: Int, maxPixels: Long): PixelSize? {
        if (widthPoints <= 0 || heightPoints <= 0 || dpi <= 0 || maxPixels <= 0) return null
        val pixelLimit = min(maxPixels, MAX_PIXELS).toDouble()
        var width = widthPoints * dpi / 72.0
        var height = heightPoints * dpi / 72.0
        var scale = min(1.0, MAX_EDGE / max(width, height))
        scale = min(scale, sqrt(pixelLimit / (width * height)))
        // The epsilon keeps an exact fit (such as 8192.0) from flooring below it.
        width = min(floor(width * scale + 1e-6), MAX_EDGE.toDouble())
        height = min(floor(height * scale + 1e-6), MAX_EDGE.toDouble())
        // Rounding can only shrink, so the result stays within both limits.
        while (width * height > pixelLimit) {
            if (width >= height) width-- else height--
        }
        if (width < MIN_EDGE || height < MIN_EDGE) return null
        return PixelSize(width.toInt(), height.toInt())
    }

    /** How many pages to render: never more than the document can accept. */
    fun pageLimit(pageCount: Int, maxPages: Int): Int =
        max(0, min(pageCount, min(maxPages, MAX_PAGES)))

    /**
     * Renders up to [PdfImportRequest.maxPages] pages into [directory].
     *
     * Every limit is checked before a page is rendered. [pageSize] returns a
     * page's size in points; [render] draws page `index` at the given pixel
     * size and encodes it into the target file. On cancellation or any
     * failure, every file written so far is deleted before rethrowing.
     */
    fun renderPages(
        directory: File,
        pageCount: Int,
        request: PdfImportRequest,
        pageSize: (index: Int) -> Pair<Int, Int>,
        render: (index: Int, size: PixelSize, target: File) -> Unit,
        isCancelled: () -> Boolean,
        onProgress: (completed: Int, total: Int) -> Unit,
    ): PdfImportResult {
        if (pageCount <= 0) throw PdfUnreadableException()
        val limit = pageLimit(pageCount, request.maxPages)
        var truncated = pageCount > limit
        var rejected = 0
        var reduced = false
        var totalBytes = 0L
        val files = ArrayList<File>()
        try {
            if (!directory.isDirectory && !directory.mkdirs()) throw IOException("No cache directory")
            onProgress(0, limit)
            for (index in 0 until limit) {
                if (isCancelled()) throw PdfImportCancelledException()
                val remaining = request.maxTotalBytes - totalBytes
                if (remaining <= 0) {
                    truncated = true
                    break
                }
                val (widthPoints, heightPoints) = pageSize(index)
                val size = renderSize(widthPoints, heightPoints, request.dpi, request.maxPagePixels)
                if (size == null) {
                    rejected++
                } else {
                    val target = File(directory, "page_$index.jpg")
                    files.add(target)
                    render(index, size, target)
                    val length = target.length()
                    when {
                        length <= 0 || length > MAX_IMAGE_BYTES -> {
                            target.delete()
                            files.remove(target)
                            rejected++
                        }
                        length > remaining -> {
                            // The document cannot hold this page; later pages
                            // would not fit either once earlier ones are added.
                            target.delete()
                            files.remove(target)
                            truncated = true
                            break
                        }
                        else -> {
                            totalBytes += length
                            // Smaller than the source limits alone would allow.
                            if (size != renderSize(widthPoints, heightPoints, request.dpi, MAX_PIXELS)) {
                                reduced = true
                            }
                        }
                    }
                }
                onProgress(index + 1, limit)
            }
            if (isCancelled()) throw PdfImportCancelledException()
        } catch (error: Throwable) {
            files.forEach { it.delete() }
            throw error
        }
        return PdfImportResult(files.map { it.path }, pageCount, rejected, truncated, reduced)
    }

    /** Removes renders left behind if the previous activity died mid-import. */
    fun clearDirectory(directory: File) {
        try {
            directory.listFiles()?.forEach { it.delete() }
        } catch (_: Exception) {
            // App-cache cleanup is best effort.
        }
    }
}
