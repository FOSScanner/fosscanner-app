package com.fosscanner.app

import java.io.File

/**
 * Remembers the document a save is about to fill, so a process killed before
 * the write finishes does not leave an empty "Scan … .pdf" in the user's
 * folder for good.
 *
 * The journal is one small app-private file holding the document URI as
 * text. It exists only between the picker returning a location and that
 * location being written or discarded. Kept free of Android types so it runs
 * as a plain JVM unit test; MainActivity supplies the provider calls.
 */
internal class PendingSaveJournal(private val file: File) {
    /** Records [uri] as the save in progress, replacing any earlier one. */
    fun record(uri: String) {
        try {
            file.parentFile?.mkdirs()
            val staging = File(file.path + ".tmp")
            staging.writeText(uri)
            if (!staging.renameTo(file)) {
                file.writeText(uri)
                staging.delete()
            }
        } catch (_: Exception) {
            // Best effort: without the journal only the cleanup is lost.
        }
    }

    /** The recorded save, if one never finished. */
    fun pending(): String? = try {
        if (file.isFile && file.length() in 1..MAX_URI_BYTES) {
            file.readText().trim().takeIf { it.isNotEmpty() && '\n' !in it }
        } else {
            null
        }
    } catch (_: Exception) {
        null
    }

    /** Forgets the save once it was written, discarded or cleaned up. */
    fun clear() {
        try {
            file.delete()
            File(file.path + ".tmp").delete()
        } catch (_: Exception) {
            // Best effort.
        }
    }

    /**
     * Takes the recorded save out of the journal, at most once: a provider
     * that keeps failing can never trigger the cleanup again.
     */
    fun take(): String? {
        val uri = pending()
        clear()
        return uri
    }

    companion object {
        const val FILE_NAME = "pending_save_target"

        // Content URIs are short; anything larger is not ours.
        private const val MAX_URI_BYTES = 8L * 1024

        /**
         * Removes the document of an interrupted save if it is still empty.
         *
         * [sizeOf] returning null (unknown, or the document is gone) keeps it:
         * it might hold data the user wants. [release] always runs so no
         * permission outlives the save. Returns true when it was deleted.
         */
        fun removeIfEmpty(
            uri: String,
            sizeOf: (uri: String) -> Long?,
            delete: (uri: String) -> Boolean,
            release: (uri: String) -> Unit,
        ): Boolean = try {
            sizeOf(uri) == 0L && delete(uri)
        } catch (_: Exception) {
            false
        } finally {
            try {
                release(uri)
            } catch (_: Exception) {
                // The grant was never taken, or is already gone.
            }
        }
    }
}
