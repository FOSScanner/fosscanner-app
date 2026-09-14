package com.fosscanner.app

import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import com.googlecode.leptonica.android.ReadFile
import com.googlecode.tesseract.android.TessBaseAPI
import com.googlecode.tesseract.android.TessPdfRenderer
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

private class OcrCancelledException : Exception()

// Keep the channel contract synchronized with lib/services/ocr_service.dart.
class MainActivity : FlutterActivity() {
    private var executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var detached = AtomicBoolean(false)
    private val rendering = AtomicBoolean(false)
    private val cancellationRequested = AtomicBoolean(false)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (executor.isShutdown) executor = Executors.newSingleThreadExecutor()
        detached = AtomicBoolean(false)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.fosscanner.app/ocr")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureTessdata" -> handleEnsureTessdata(result)
                "createSearchablePdf" -> handleCreateSearchablePdf(call, result)
                "cancelSearchablePdf" -> handleCancelSearchablePdf(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        detached.set(true)
        channel?.setMethodCallHandler(null)
        channel = null
        // Let the active native call finish and release its resources. Interrupting
        // the Java worker cannot safely interrupt Tesseract's native renderer.
        executor.shutdown()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun submit(result: MethodChannel.Result, work: () -> Any?) {
        try {
            executor.execute {
                try {
                    val value = work()
                    mainHandler.post { result.success(value) }
                } catch (e: OcrCancelledException) {
                    mainHandler.post { result.error("ocr_cancelled", "OCR export cancelled", null) }
                } catch (e: Exception) {
                    // Do not expose native exception messages, paths, or OCR text.
                    mainHandler.post { result.error("ocr_failed", "OCR operation failed", null) }
                } catch (e: LinkageError) {
                    mainHandler.post { result.error("ocr_unavailable", "OCR native library is unavailable", null) }
                } catch (e: OutOfMemoryError) {
                    mainHandler.post { result.error("ocr_memory", "Not enough memory for OCR", null) }
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error("ocr_unavailable", "OCR worker is unavailable", null)
        }
    }

    private fun handleEnsureTessdata(result: MethodChannel.Result) {
        val filesDir = applicationContext.filesDir
        val assets = applicationContext.assets
        val assetKey = FlutterInjector.instance().flutterLoader()
            .getLookupKeyForAsset("assets/tessdata/${OcrModelStore.filename}")
        submit(result) {
            OcrModelStore.install(File(filesDir, "tessdata")) { assets.open(assetKey) }
            null
        }
    }

    private fun handleCreateSearchablePdf(call: MethodCall, result: MethodChannel.Result) {
        val imagePaths = call.argument<List<String>>("imagePaths")
        val outputPath = call.argument<String>("outputPath")
        if (imagePaths.isNullOrEmpty() || imagePaths.size > 100 || outputPath == null) {
            result.error("invalid_args", "Between 1 and 100 images and an output path are required", null)
            return
        }
        if (!rendering.compareAndSet(false, true)) {
            result.error("ocr_busy", "An OCR export is already running", null)
            return
        }
        cancellationRequested.set(false)
        if (executor.isShutdown) {
            rendering.set(false)
            result.error("ocr_unavailable", "OCR worker is unavailable", null)
            return
        }
        val cacheDir = applicationContext.cacheDir
        val filesDir = applicationContext.filesDir
        val jobDetached = detached
        submit(result) {
            var jobDirectory: File? = null
            var succeeded = false
            try {
                val output = File(outputPath).canonicalFile
                val directory = requireNotNull(output.parentFile)
                require(directory.parentFile == cacheDir.canonicalFile && directory.name.startsWith("fosscanner_ocr_"))
                require(output.name == "document" && directory.isDirectory)
                jobDirectory = directory
                val images = imagePaths.map { File(it).canonicalFile }
                var encodedBytes = 0L
                for ((index, image) in images.withIndex()) {
                    require(image.parentFile == directory && image.name == "page_$index.jpg")
                    require(image.isFile && image.length() in 1..MAX_IMAGE_BYTES)
                    encodedBytes += image.length()
                    require(encodedBytes <= MAX_DOCUMENT_BYTES)
                }
                checkNotCancelled(jobDetached)
                renderPdf(filesDir, images, output.path, jobDetached)
                checkNotCancelled(jobDetached)
                succeeded = true
                "$outputPath.pdf"
            } finally {
                // Native handles close before this block and the channel reply,
                // so Flutter can read or remove the files without a race.
                try {
                    if (!succeeded) jobDirectory?.deleteRecursively()
                } finally {
                    rendering.set(false)
                }
            }
        }
    }

    private fun handleCancelSearchablePdf(result: MethodChannel.Result) {
        if (rendering.get()) cancellationRequested.set(true)
        result.success(null)
    }

    private fun renderPdf(filesDir: File, images: List<File>, outputPath: String, jobDetached: AtomicBoolean) {
        val baseApi = TessBaseAPI()
        try {
            check(baseApi.init(filesDir.absolutePath, OcrModelStore.language, TessBaseAPI.OEM_LSTM_ONLY))
            val renderer = TessPdfRenderer(baseApi, outputPath)
            try {
                check(baseApi.beginDocument(renderer, "FOSScanner"))
                for (image in images) {
                    checkNotCancelled(jobDetached)
                    // Mirror image_metadata.dart's source limits before allocating
                    // bitmap/Pix buffers, including pass-through imported pages.
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(image.path, bounds)
                    require(bounds.outWidth in 1..8192 && bounds.outHeight in 1..8192)
                    require(bounds.outWidth.toLong() * bounds.outHeight <= 20_000_000)
                    val bitmap = requireNotNull(BitmapFactory.decodeFile(image.path))
                    val pix = try {
                        requireNotNull(ReadFile.readBitmap(bitmap))
                    } finally {
                        bitmap.recycle()
                    }
                    try {
                        check(baseApi.addPageToDocument(pix, image.path, renderer))
                    } finally {
                        pix.recycle()
                    }
                    check(File("$outputPath.pdf").length() <= MAX_DOCUMENT_BYTES)
                    reportProgress(images.size, images.indexOf(image) + 1)
                }
                checkNotCancelled(jobDetached)
                check(baseApi.endDocument(renderer))
            } finally {
                renderer.recycle()
            }
        } finally {
            baseApi.recycle()
        }
        check(File("$outputPath.pdf").length() in 1..MAX_DOCUMENT_BYTES)
        // Tesseract4Android 4.9.0's JNI addPageToDocument ignores ProcessPage's
        // boolean result. Validate the finished document before reporting success.
        ParcelFileDescriptor.open(File("$outputPath.pdf"), ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { pdf -> check(pdf.pageCount == images.size) }
        }
    }

    private fun checkNotCancelled(jobDetached: AtomicBoolean) {
        if (jobDetached.get() || cancellationRequested.get()) {
            throw OcrCancelledException()
        }
    }

    private fun reportProgress(total: Int, completed: Int) {
        mainHandler.post {
            channel?.invokeMethod(
                "ocrProgress",
                mapOf("completed" to completed, "total" to total),
            )
        }
    }

    companion object {
        private const val MAX_IMAGE_BYTES = 32L * 1024 * 1024
        private const val MAX_DOCUMENT_BYTES = 256L * 1024 * 1024
    }
}
