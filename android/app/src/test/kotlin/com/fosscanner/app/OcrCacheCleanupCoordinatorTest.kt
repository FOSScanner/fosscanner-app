package com.fosscanner.app

import java.io.File
import java.util.concurrent.RejectedExecutionException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OcrCacheCleanupCoordinatorTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun removesCapturedOcrDirectoriesOnceWithoutTouchingLaterJobsOrUnrelatedEntries() {
        val cache = temporary.newFolder("cache")
        val firstOrphan = File(cache, "fosscanner_ocr_first").also { assertTrue(it.mkdir()) }
        val secondOrphan = File(cache, "fosscanner_ocr_second").also { assertTrue(it.mkdir()) }
        File(firstOrphan, "page_0.jpg").writeText("page")
        File(secondOrphan, "document.pdf").writeText("partial")
        val unrelatedDirectory = File(cache, "draft").also { assertTrue(it.mkdir()) }
        val similarlyNamedFile = File(cache, "fosscanner_ocr_file").also { it.writeText("keep") }
        val deferred = mutableListOf<Runnable>()
        val cleanup = OcrCacheCleanupCoordinator()

        cleanup.schedule(cache, deferred::add)
        val newJob = File(cache, "fosscanner_ocr_created_after_capture").also { assertTrue(it.mkdir()) }
        cleanup.schedule(cache, deferred::add)

        assertEquals(1, deferred.size)
        deferred.single().run()
        assertFalse(firstOrphan.exists())
        assertFalse(secondOrphan.exists())
        assertTrue(newJob.isDirectory)
        assertTrue(unrelatedDirectory.isDirectory)
        assertTrue(similarlyNamedFile.isFile)
    }

    @Test fun treatsScanAndDispatchFailuresAsBestEffort() {
        val deniedCache = object : File(temporary.root, "denied") {
            override fun listFiles(): Array<File> = throw SecurityException("denied")
        }
        val rejectedCache = temporary.newFolder("rejected")
        assertTrue(File(rejectedCache, "fosscanner_ocr_orphan").mkdir())

        OcrCacheCleanupCoordinator().schedule(deniedCache) {
            throw AssertionError("A failed scan must not dispatch cleanup")
        }
        OcrCacheCleanupCoordinator().schedule(rejectedCache) {
            throw RejectedExecutionException("shutting down")
        }
    }

    @Test fun continuesAfterAPlatformDeletionFailure() {
        val cache = temporary.newFolder("deletion-failure")
        val blockedPath = File(cache, "fosscanner_ocr_blocked").also { assertTrue(it.mkdir()) }
        val blocked = object : File(blockedPath.path) {
            override fun delete(): Boolean = throw SecurityException("denied")
        }
        val removable = File(cache, "fosscanner_ocr_removable").also { assertTrue(it.mkdir()) }
        val listing = object : File(cache.path) {
            override fun listFiles(): Array<File> = arrayOf(blocked, removable)
        }
        val deferred = mutableListOf<Runnable>()

        OcrCacheCleanupCoordinator().schedule(listing, deferred::add)
        deferred.single().run()

        assertTrue(blockedPath.isDirectory)
        assertFalse(removable.exists())
    }
}
