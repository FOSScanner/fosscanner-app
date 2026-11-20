package com.fosscanner.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.view.WindowManager
import android.provider.DocumentsContract
import com.googlecode.leptonica.android.ReadFile
import com.googlecode.tesseract.android.TessBaseAPI
import com.googlecode.tesseract.android.TessPdfRenderer
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

private class OcrCancelledException : Exception()

// Keep the channel contract synchronized with lib/services/ocr_service.dart.
class MainActivity : FlutterActivity() {
    private var executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var privacyChannel: MethodChannel? = null
    private var detached = AtomicBoolean(false)
    private val rendering = AtomicBoolean(false)
    private val cancellationRequested = AtomicBoolean(false)
    // The one save waiting for the system document picker, if any.
    private var pendingSave: PendingSave? = null

    private class PendingSave(val result: MethodChannel.Result, val source: File)

    // Shared images are copied off the UI thread on their own worker, so a
    // running OCR export never delays them (Dart blocks intake during export).
    private var sharedImageExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var sharedImageChannel: MethodChannel? = null
    private val sharedImages by lazy {
        SharedImageInbox<Uri>(
            directory = File(cacheDir, SharedImageInbox.DIRECTORY_NAME),
            open = { contentResolver.openInputStream(it) },
            typeOf = { contentResolver.getType(it) },
            maxImageBytes = MAX_IMAGE_BYTES,
            maxImages = MAX_PAGES,
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        orphanCacheCleanup.schedule(applicationContext.cacheDir, executor::execute)
        // No Dart isolate of this activity can hold a copied path yet. The
        // single worker runs this cleanup before any later copy.
        val inbox = sharedImages
        sharedImageExecutor.execute { inbox.clearDirectory() }
        super.onCreate(savedInstanceState)
        // Scans are often IDs or bank statements: keep page content out of the
        // Recents thumbnail without blocking screenshots. Older APIs have no
        // equivalent short of FLAG_SECURE, which is the opt-in below.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setRecentsScreenshotEnabled(false)
        }
        applySecureScreen()
        // After recreation the intent was already delivered; only re-read it
        // if Dart had not pulled its images yet.
        if (savedInstanceState == null || savedInstanceState.getBoolean(KEY_SHARE_PENDING)) {
            receiveSharedImages(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (receiveSharedImages(intent)) {
            sharedImageChannel?.invokeMethod("sharedImagesAvailable", null)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_SHARE_PENDING, sharedImages.hasPending)
    }

    /**
     * Queues image URIs from a share intent. Only the temporary read grant
     * that comes with the intent is used: no persistable permission is taken,
     * and nothing is read until Dart asks for the images.
     */
    private fun receiveSharedImages(intent: Intent?): Boolean {
        if (intent == null) return false
        val streams = try {
            SharedImageIntents.sharedStreams(
                action = intent.action,
                mimeType = intent.type,
                flags = intent.flags,
                single = if (intent.action == Intent.ACTION_SEND) singleStream(intent) else null,
                multiple = if (intent.action == Intent.ACTION_SEND_MULTIPLE) multipleStreams(intent) else null,
            )
        } catch (_: Exception) {
            // Malformed extras from another app must not crash the scanner.
            emptyList()
        }
        return sharedImages.offer(streams)
    }

    private fun singleStream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }

    private fun multipleStreams(intent: Intent): List<Uri?>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }

    private fun handleTakeSharedImages(call: MethodCall, result: MethodChannel.Result) {
        val maxCount = call.argument<Int>("maxCount") ?: 0
        val inbox = sharedImages
        try {
            sharedImageExecutor.execute {
                try {
                    val batch = inbox.take(maxCount)
                    mainHandler.post { result.success(batch.toChannelMap()) }
                } catch (e: Exception) {
                    // Do not expose provider exception messages or URIs.
                    mainHandler.post { result.error("share_failed", "Could not read shared images", null) }
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error("share_unavailable", "Shared image worker is unavailable", null)
        }
    }

    // FLAG_SECURE blocks screenshots, screen recording and the Recents
    // thumbnail on every API level. The choice is process-wide so it survives
    // activity recreation (rotation, theme change) until Flutter changes it.
    private fun applySecureScreen() {
        if (secureScreen) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

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
                "savePdfDocument" -> handleSavePdfDocument(call, result)
                else -> result.notImplemented()
            }
        }
        // Keep this contract synchronized with lib/services/screen_privacy.dart.
        privacyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.fosscanner.app/screen_privacy")
        privacyChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecureScreen" -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled == null) {
                        result.error("invalid_args", "A boolean 'enabled' argument is required", null)
                    } else {
                        secureScreen = enabled
                        applySecureScreen()
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        if (sharedImageExecutor.isShutdown) sharedImageExecutor = Executors.newSingleThreadExecutor()
        sharedImageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARED_IMAGES_CHANNEL)
        sharedImageChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeSharedImages" -> handleTakeSharedImages(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        detached.set(true)
        channel?.setMethodCallHandler(null)
        channel = null
        privacyChannel?.setMethodCallHandler(null)
        privacyChannel = null
        sharedImageChannel?.setMethodCallHandler(null)
        sharedImageChannel = null
        sharedImageExecutor.shutdown()
        // Its Dart caller is gone with the engine; nothing is left to answer.
        pendingSave = null
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
        // Dart sizes each page through its density (page = pixels / DPI), so
        // export presets and A4/Letter pages need one value per image.
        val pageDpis = PdfExportContract.pageDpis(call.argument<Any>("pageDpis"), imagePaths.size)
        if (pageDpis == null) {
            result.error("invalid_args", "One valid density per image is required", null)
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
                require(
                    directory.parentFile == cacheDir.canonicalFile &&
                        directory.name.startsWith(OcrCacheCleanupCoordinator.JOB_PREFIX),
                )
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
                renderPdf(filesDir, images, pageDpis, output.path, jobDetached)
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

    // Lets the user pick a location with the system picker (ACTION_CREATE_DOCUMENT):
    // no storage permission, works without Google apps, and the user can rename
    // the suggested file. Replies true when saved and false when cancelled.
    private fun handleSavePdfDocument(call: MethodCall, result: MethodChannel.Result) {
        if (pendingSave != null) {
            result.error("save_busy", "A save is already waiting for a location", null)
            return
        }
        val source = PdfExportContract.exportFile(
            applicationContext.cacheDir,
            call.argument<String>("sourcePath"),
        )
        if (source == null) {
            result.error("invalid_args", "An exported PDF is required", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("application/pdf")
            .putExtra(Intent.EXTRA_TITLE, PdfExportContract.documentTitle(call.argument<String>("fileName")))
        pendingSave = PendingSave(result, source)
        try {
            startActivityForResult(intent, SAVE_DOCUMENT_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pendingSave = null
            result.error("save_unavailable", "No document picker is available", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_DOCUMENT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val pending = pendingSave ?: return
        pendingSave = null
        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null) {
            pending.result.success(false)
            return
        }
        val resolver = applicationContext.contentResolver
        // Streams the file in chunks off the main thread; it can be large.
        Thread {
            try {
                val output = resolver.openOutputStream(destination, "w")
                    ?: throw IOException("No output stream")
                output.use { stream ->
                    pending.source.inputStream().use { input -> input.copyTo(stream, 64 * 1024) }
                }
                mainHandler.post { pending.result.success(true) }
            } catch (e: Exception) {
                // Do not leave an empty or truncated document at the chosen place.
                try {
                    DocumentsContract.deleteDocument(resolver, destination)
                } catch (_: Exception) {
                    // Best effort; some providers do not support deletion.
                }
                // Do not expose paths or provider messages to Dart.
                mainHandler.post { pending.result.error("save_failed", "Could not write the document", null) }
            }
        }.start()
    }

    private fun handleCancelSearchablePdf(result: MethodChannel.Result) {
        if (rendering.get()) cancellationRequested.set(true)
        result.success(null)
    }

    private fun renderPdf(
        filesDir: File,
        images: List<File>,
        pageDpis: List<Int>,
        outputPath: String,
        jobDetached: AtomicBoolean,
    ) {
        require(pageDpis.size == images.size)
        val baseApi = TessBaseAPI()
        try {
            check(baseApi.init(filesDir.absolutePath, OcrModelStore.language, TessBaseAPI.OEM_LSTM_ONLY))
            val renderer = TessPdfRenderer(baseApi, outputPath)
            try {
                check(baseApi.beginDocument(renderer, "FOSScanner"))
                for ((index, image) in images.withIndex()) {
                    checkNotCancelled(jobDetached)
                    // Tesseract reads this for every page, and its PDF renderer
                    // sizes the page as pixels / DPI.
                    check(baseApi.setVariable("user_defined_dpi", pageDpis[index].toString()))
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
                    reportProgress(images.size, index + 1)
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
        private val orphanCacheCleanup = OcrCacheCleanupCoordinator()
        @Volatile private var secureScreen = false
        private const val SAVE_DOCUMENT_REQUEST = 0x5AFE
        private const val MAX_IMAGE_BYTES = 32L * 1024 * 1024
        private const val MAX_DOCUMENT_BYTES = 256L * 1024 * 1024

        // Mirror lib/services/image_metadata.dart's maxDocumentPages.
        private const val MAX_PAGES = 100
        private const val SHARED_IMAGES_CHANNEL = "com.fosscanner.app/shared_images"
        private const val KEY_SHARE_PENDING = "fosscanner.sharePending"
    }
}
