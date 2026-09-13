package com.fosscanner.app

import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest

internal object OcrModelStore {
    const val language = "Latin"
    const val filename = "$language.traineddata"
    const val sha256 = "6dbdaf8ecc6c40f025c2648bf3b3f3fbffe073e1fd2df2047fde2e2b2f020d53"

    fun install(directory: File, openModel: () -> InputStream) {
        installVerified(directory, filename, sha256, openModel)
    }

    // Tiny fixtures exercise recovery without loading the full model in tests.
    internal fun installVerified(directory: File, name: String, expectedHash: String, openModel: () -> InputStream) {
        require(name == File(name).name && name != "." && name != "..")
        check(directory.isDirectory || directory.mkdirs())
        val target = File(directory, name)
        if (target.isFile && target.inputStream().use { digest(it) } == expectedHash) return

        val temporary = File.createTempFile("model-", ".tmp", directory)
        try {
            FileOutputStream(temporary).use {
                openModel().use { source -> source.copyTo(it) }
                it.fd.sync()
            }
            require(temporary.inputStream().use { digest(it) } == expectedHash)
            // Android private storage is one filesystem; rename atomically
            // replaces the target without deleting a valid model first.
            check(temporary.renameTo(target)) { "Could not install OCR model" }
        } finally {
            temporary.delete()
        }
    }

    private fun digest(input: InputStream): String {
        val hash = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            hash.update(buffer, 0, count)
        }
        return hex(hash.digest())
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}
