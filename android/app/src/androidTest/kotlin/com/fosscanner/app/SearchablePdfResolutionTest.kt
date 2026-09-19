package com.fosscanner.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

class SearchablePdfResolutionTest {
    private lateinit var context: Context
    private lateinit var directory: File

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        directory = File(context.cacheDir, "searchable-pdf-resolution-test")
        directory.deleteRecursively()
        check(directory.mkdirs())

        OcrModelStore.install(File(context.filesDir, "tessdata")) {
            context.assets.open("flutter_assets/assets/tessdata/${OcrModelStore.filename}")
        }
    }

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    @Test
    fun rendersPagesAtTheScannerDpiInInputOrder() {
        val first = createJpeg("page_0.jpg", 1500, 2100, "FIRST PAGE")
        val second = createJpeg("page_1.jpg", 1200, 1800, "SECOND PAGE")
        val output = File(directory, "document")

        renderWithActivity(listOf(first, second), output.path)

        ParcelFileDescriptor.open(
            File("${output.path}.pdf"),
            ParcelFileDescriptor.MODE_READ_ONLY,
        ).use { descriptor ->
            PdfRenderer(descriptor).use { pdf ->
                assertEquals(2, pdf.pageCount)
                val pageSizes = (0 until pdf.pageCount).map { index ->
                    pdf.openPage(index).use { page -> page.width to page.height }
                }
                assertEquals(listOf(720 to 1008, 576 to 864), pageSizes)
            }
        }
    }

    private fun createJpeg(name: String, width: Int, height: Int, text: String): File {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.WHITE)
            canvas.drawText(
                text,
                120f,
                240f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.BLACK
                    textSize = 96f
                },
            )
            return File(directory, name).also { file ->
                file.outputStream().use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output))
                }
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun renderWithActivity(images: List<File>, outputPath: String) {
        lateinit var activity: MainActivity
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            activity = MainActivity()
        }
        val method = MainActivity::class.java.getDeclaredMethod(
            "renderPdf",
            File::class.java,
            List::class.java,
            String::class.java,
            AtomicBoolean::class.java,
        )
        method.isAccessible = true
        try {
            method.invoke(activity, context.filesDir, images, outputPath, AtomicBoolean(false))
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }
}
