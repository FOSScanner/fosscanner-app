package com.fosscanner.app

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

internal class OcrCacheCleanupCoordinator {
    private val scheduled = AtomicBoolean(false)

    fun schedule(cacheDirectory: File, execute: (Runnable) -> Unit) {
        if (!scheduled.compareAndSet(false, true)) return

        val orphanedJobs = try {
            cacheDirectory.listFiles()
                ?.filter { it.isDirectory && it.name.startsWith(JOB_PREFIX) }
                .orEmpty()
        } catch (_: Exception) {
            return
        }
        if (orphanedJobs.isEmpty()) return

        try {
            execute(
                Runnable {
                    orphanedJobs.forEach { job ->
                        try {
                            job.deleteRecursively()
                        } catch (_: Exception) {
                            // App-cache cleanup is best effort.
                        }
                    }
                },
            )
        } catch (_: Exception) {
            // Activity shutdown can reject the cleanup task.
        }
    }

    companion object {
        const val JOB_PREFIX = "fosscanner_ocr_"
    }
}
