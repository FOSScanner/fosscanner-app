package com.fosscanner.app

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SharedImageInboxTest {
    @get:Rule val temporary = TemporaryFolder()

    private val send = SharedImageIntents.ACTION_SEND
    private val sendMultiple = SharedImageIntents.ACTION_SEND_MULTIPLE

    @Test fun actionConstantsMatchTheAndroidFramework() {
        // android.content.Intent values; the helper must stay Android-free.
        assertEquals("android.intent.action.SEND", send)
        assertEquals("android.intent.action.SEND_MULTIPLE", sendMultiple)
        assertEquals(0x00100000, SharedImageIntents.FLAG_LAUNCHED_FROM_HISTORY)
    }

    @Test fun parsesSingleAndMultipleImageShares() {
        assertEquals(listOf("a"), SharedImageIntents.sharedStreams(send, "image/jpeg", 0, "a", null))
        assertEquals(
            listOf("a", "b"),
            SharedImageIntents.sharedStreams(sendMultiple, "image/*", 0, null, listOf("a", null, "b", "a")),
        )
        assertEquals(listOf("a"), SharedImageIntents.sharedStreams(send, " IMAGE/PNG ", 0, "a", null))
    }

    @Test fun ignoresNonImageMissingOrReplayedShares() {
        assertEquals(emptyList<String>(), SharedImageIntents.sharedStreams(send, "text/plain", 0, "a", null))
        assertEquals(emptyList<String>(), SharedImageIntents.sharedStreams(send, null, 0, "a", null))
        assertEquals(emptyList<String>(), SharedImageIntents.sharedStreams(send, "image/png", 0, null, null))
        assertEquals(emptyList<String>(), SharedImageIntents.sharedStreams(sendMultiple, "image/png", 0, null, null))
        assertEquals(
            emptyList<String>(),
            SharedImageIntents.sharedStreams("android.intent.action.VIEW", "image/png", 0, "a", null),
        )
        assertEquals(
            emptyList<String>(),
            SharedImageIntents.sharedStreams(send, "image/png", SharedImageIntents.FLAG_LAUNCHED_FROM_HISTORY, "a", null),
        )
        assertEquals(
            emptyList<String>(),
            SharedImageIntents.sharedStreams("android.intent.action.MAIN", null, 0, null, null),
        )
    }

    private class Source(val bytes: ByteArray?, val type: String? = "image/png", val failOpen: Boolean = false)

    private fun inbox(directory: File, maxImageBytes: Long = 8, maxImages: Int = 3) =
        SharedImageInbox<Source>(
            directory = directory,
            open = { source ->
                if (source.failOpen) throw SecurityException("permission denial content://secret")
                source.bytes?.let(::ByteArrayInputStream)
            },
            typeOf = { it.type },
            maxImageBytes = maxImageBytes,
            maxImages = maxImages,
        )

    @Test fun copiesImagesIntoAppOwnedFilesAndDrainsTheQueue() {
        val directory = File(temporary.root, SharedImageInbox.DIRECTORY_NAME)
        val inbox = inbox(directory)
        val first = Source(byteArrayOf(1, 2, 3))
        val second = Source(byteArrayOf(4, 5), type = null)
        assertTrue(inbox.offer(listOf(first, second, first)))
        assertTrue(inbox.hasPending)

        val batch = inbox.take(maxCount = 10)

        assertEquals(2, batch.paths.size)
        assertEquals(0, batch.rejected)
        assertFalse(batch.truncated)
        assertTrue(batch.paths.all { File(it).parentFile == directory })
        assertArrayEquals(byteArrayOf(1, 2, 3), File(batch.paths[0]).readBytes())
        assertArrayEquals(byteArrayOf(4, 5), File(batch.paths[1]).readBytes())
        assertFalse(inbox.hasPending)
        assertEquals(SharedImageBatch(emptyList(), 0, false), inbox.take(maxCount = 10))
        assertEquals(
            mapOf("paths" to batch.paths, "rejected" to 0, "truncated" to false),
            batch.toChannelMap(),
        )
    }

    @Test fun rejectsNonImagesUnreadableEmptyAndOversizedItemsWithoutLeavingFiles() {
        val directory = File(temporary.root, SharedImageInbox.DIRECTORY_NAME)
        val inbox = inbox(directory, maxImages = 10)
        inbox.offer(
            listOf(
                Source(byteArrayOf(1), type = "application/pdf"),
                Source(null),
                Source(byteArrayOf(1), failOpen = true),
                Source(ByteArray(0)),
                Source(ByteArray(9)),
                Source(ByteArray(8)),
            ),
        )

        val batch = inbox.take(maxCount = 10)

        assertEquals(5, batch.rejected)
        assertEquals(1, batch.paths.size)
        assertEquals(listOf(File(batch.paths.single()).name), directory.list()!!.toList())
    }

    @Test fun respectsTheRemainingPageCountAndNeverReplaysDroppedShares() {
        val directory = temporary.newFolder("shared")
        val inbox = inbox(directory, maxImages = 3)
        assertFalse(inbox.offer(emptyList()))
        inbox.offer((1..5).map { Source(byteArrayOf(it.toByte())) })

        val batch = inbox.take(maxCount = 2)

        assertEquals(2, batch.paths.size)
        assertTrue(batch.truncated)
        assertFalse(inbox.hasPending)
        assertEquals(SharedImageBatch(emptyList(), 0, false), inbox.take(maxCount = 2))

        inbox.offer(listOf(Source(byteArrayOf(1))))
        val full = inbox.take(maxCount = 0)
        assertEquals(SharedImageBatch(emptyList(), 0, true), full)
    }

    @Test fun clearDirectoryRemovesCopiesLeftByAnEarlierActivity() {
        val directory = temporary.newFolder("shared")
        File(directory, "shared_0.img").writeBytes(byteArrayOf(1))
        inbox(directory).clearDirectory()
        assertEquals(0, directory.list()!!.size)
        // A missing directory is not an error.
        inbox(File(temporary.root, "missing")).clearDirectory()
    }

    @Test fun boundedCopyDeletesPartialFilesOnReadFailure() {
        val target = File(temporary.root, "partial.img")
        val failing = object : InputStream() {
            var calls = 0
            override fun read(): Int = throw IOException()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (calls++ == 0) return 1.also { b[off] = 7 }
                throw IOException("provider detail")
            }
        }
        try {
            SharedImageInbox.copyBounded(failing, target, maxBytes = 8)
        } catch (_: IOException) {
            // Expected.
        }
        assertFalse(target.exists())
        assertTrue(SharedImageInbox.copyBounded(ByteArrayInputStream(ByteArray(8)), target, maxBytes = 8))
        assertEquals(8, target.length())
    }
}
