package com.fosscanner.app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PendingSaveJournalTest {
    @get:Rule val temporary = TemporaryFolder()

    private val uri = "content://com.android.externalstorage.documents/document/primary%3ADownload%2FScan.pdf"

    private fun journal() = PendingSaveJournal(File(temporary.root, "state/${PendingSaveJournal.FILE_NAME}"))

    @Test fun recordsReplacesAndClearsTheSaveInProgress() {
        val journal = journal()
        assertNull(journal.pending())
        journal.record(uri)
        assertEquals(uri, journal.pending())
        // A new save replaces the old one; only one save runs at a time.
        journal.record("$uri-2")
        assertEquals("$uri-2", journal.pending())
        // A new activity reads what the killed process wrote.
        assertEquals("$uri-2", journal().pending())
        journal.clear()
        assertNull(journal.pending())
        assertFalse(File(temporary.root, "state/${PendingSaveJournal.FILE_NAME}.tmp").exists())
    }

    @Test fun takeHandsOutARecordedSaveOnlyOnce() {
        val journal = journal()
        journal.record(uri)
        assertEquals(uri, journal.take())
        assertNull(journal.take())
        assertNull(journal().pending())
    }

    @Test fun ignoresDamagedJournals() {
        val file = File(temporary.root, PendingSaveJournal.FILE_NAME)
        val journal = PendingSaveJournal(file)
        file.writeText("")
        assertNull(journal.pending())
        file.writeText("content://a\ncontent://b")
        assertNull(journal.pending())
        file.writeText("x".repeat(9 * 1024))
        assertNull(journal.pending())
        assertNull(journal.take())
        assertFalse(file.exists())
    }

    @Test fun deletesOnlyADocumentThatIsStillEmpty() {
        for ((size, expected) in listOf(0L to true, 1L to false, 4096L to false, null to false)) {
            val deleted = mutableListOf<String>()
            val released = mutableListOf<String>()
            val removed = PendingSaveJournal.removeIfEmpty(
                uri,
                sizeOf = { size },
                delete = { deleted.add(it) },
                release = { released.add(it) },
            )
            assertEquals("size $size", expected, removed)
            assertEquals("size $size", if (expected) listOf(uri) else emptyList<String>(), deleted)
            // The write grant never outlives the save, whatever the outcome.
            assertEquals("size $size", listOf(uri), released)
        }
    }

    @Test fun providerFailuresKeepTheDocumentAndStillReleaseTheGrant() {
        val released = mutableListOf<String>()
        assertFalse(
            PendingSaveJournal.removeIfEmpty(
                uri,
                sizeOf = { throw SecurityException("grant revoked") },
                delete = { throw AssertionError("must not delete") },
                release = { released.add(it) },
            ),
        )
        assertEquals(listOf(uri), released)
        assertFalse(
            PendingSaveJournal.removeIfEmpty(
                uri,
                sizeOf = { 0L },
                delete = { false },
                release = { throw SecurityException("no grant") },
            ),
        )
        assertTrue(
            PendingSaveJournal.removeIfEmpty(
                uri,
                sizeOf = { 0L },
                delete = { true },
                release = { throw SecurityException("no grant") },
            ),
        )
    }
}
