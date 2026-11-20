package com.fosscanner.app

import java.io.File
import java.io.IOException
import java.io.InputStream

/**
 * Images shared into the app (ACTION_SEND / ACTION_SEND_MULTIPLE with an
 * image MIME type), kept free of Android types so the parsing and copying
 * rules run as plain JVM unit tests. [T] is `android.net.Uri` in the app.
 *
 * Keep the channel contract synchronized with
 * lib/services/shared_image_inbox.dart.
 */
internal object SharedImageIntents {
    const val ACTION_SEND = "android.intent.action.SEND"
    const val ACTION_SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"

    // Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY: reopening the task from
    // Recents redelivers the original share, which was already handled.
    const val FLAG_LAUNCHED_FROM_HISTORY = 0x00100000

    fun isImageMimeType(type: String?): Boolean =
        type != null && type.trim().lowercase().startsWith("image/")

    /** The shared streams of an intent, in order and without duplicates. */
    fun <T : Any> sharedStreams(
        action: String?,
        mimeType: String?,
        flags: Int,
        single: T?,
        multiple: List<T?>?,
    ): List<T> {
        if (flags and FLAG_LAUNCHED_FROM_HISTORY != 0) return emptyList()
        if (!isImageMimeType(mimeType)) return emptyList()
        val streams = when (action) {
            ACTION_SEND -> listOfNotNull(single)
            ACTION_SEND_MULTIPLE -> multiple.orEmpty().filterNotNull()
            else -> emptyList()
        }
        return streams.distinct()
    }
}

/** What one `takeSharedImages` call hands to Dart. */
internal data class SharedImageBatch(
    /** App-owned cache files; Dart deletes each one after reading it. */
    val paths: List<String>,
    /** Shared items that were not images, unreadable, or over the size limit. */
    val rejected: Int,
    /** More images were shared than the document could still accept. */
    val truncated: Boolean,
) {
    fun toChannelMap(): Map<String, Any> =
        mapOf("paths" to paths, "rejected" to rejected, "truncated" to truncated)
}

/**
 * Pending shared images. [offer] runs on the main thread when an intent
 * arrives; [take] copies on a worker thread when Dart pulls them, so URI
 * reads never block the UI and nothing is copied while a saved draft is
 * still unresolved on the Dart side.
 */
internal class SharedImageInbox<T : Any>(
    private val directory: File,
    private val open: (T) -> InputStream?,
    private val typeOf: (T) -> String?,
    private val maxImageBytes: Long,
    private val maxImages: Int,
) {
    private val lock = Any()
    private val pending = ArrayList<T>()
    private var droppedWhilePending = false
    private var sequence = 0L

    val hasPending: Boolean
        get() = synchronized(lock) { pending.isNotEmpty() || droppedWhilePending }

    /** Queues [items]; returns true when Dart should be told to pull. */
    fun offer(items: List<T>): Boolean {
        if (items.isEmpty()) return false
        synchronized(lock) {
            for (item in items) {
                if (item in pending) continue
                if (pending.size >= maxImages) {
                    droppedWhilePending = true
                } else {
                    pending.add(item)
                }
            }
        }
        return true
    }

    /**
     * Drains every pending item, copying at most [maxCount] of them. Items
     * beyond that are dropped and reported as [SharedImageBatch.truncated],
     * so an old share can never resurface on a later pull.
     */
    fun take(maxCount: Int): SharedImageBatch {
        val items: List<T>
        var truncated: Boolean
        synchronized(lock) {
            items = ArrayList(pending)
            truncated = droppedWhilePending
            pending.clear()
            droppedWhilePending = false
        }
        val limit = maxCount.coerceIn(0, maxImages)
        if (items.size > limit) truncated = true
        val paths = ArrayList<String>()
        var rejected = 0
        for (item in items.take(limit)) {
            val path = copy(item)
            if (path == null) rejected++ else paths.add(path)
        }
        return SharedImageBatch(paths, rejected, truncated)
    }

    private fun copy(item: T): String? {
        val type = try {
            typeOf(item)
        } catch (_: Exception) {
            null
        }
        // An unknown type is left to the Dart decoder, which rejects non-images.
        if (type != null && !SharedImageIntents.isImageMimeType(type)) return null
        val target = synchronized(lock) { File(directory, "shared_${sequence++}.img") }
        return try {
            if (!directory.isDirectory && !directory.mkdirs()) return null
            val input = open(item) ?: return null
            val copied = input.use { copyBounded(it, target, maxImageBytes) }
            if (copied) target.path else null
        } catch (_: Exception) {
            // Never surface provider exception text; the item is just rejected.
            target.delete()
            null
        }
    }

    /** Removes copies left behind if the previous activity died mid-import. */
    fun clearDirectory() {
        try {
            directory.listFiles()?.forEach { it.delete() }
        } catch (_: Exception) {
            // App-cache cleanup is best effort.
        }
    }

    companion object {
        const val DIRECTORY_NAME = "fosscanner_shared"

        /**
         * Copies [input] into [target], refusing empty sources and anything
         * over [maxBytes] without buffering more than one chunk past it.
         */
        fun copyBounded(input: InputStream, target: File, maxBytes: Long): Boolean {
            var total = 0L
            var withinLimit = true
            try {
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > maxBytes) {
                            withinLimit = false
                            break
                        }
                        output.write(buffer, 0, read)
                    }
                }
            } catch (error: IOException) {
                target.delete()
                throw error
            }
            if (!withinLimit || total == 0L) {
                target.delete()
                return false
            }
            return true
        }
    }
}
