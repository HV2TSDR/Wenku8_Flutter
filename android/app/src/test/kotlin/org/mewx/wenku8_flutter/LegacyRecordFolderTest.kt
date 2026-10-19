package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.Test

class LegacyRecordFolderTest {
    private fun folder(name: String) = LegacyRecordDocument(name, name, true, 0)
    private val records = listOf(LegacyRecordDocument("saves/bookshelf_local.wk8", "bookshelf_local.wk8", false, 1), LegacyRecordDocument("saves/cert.wk8", "cert.wk8", false, 1))
    @Test fun selectingSavesUsesItsRecords() {
        assertSame(records, LegacyRecordFolder.locate(records) { error("Must not crawl") })
    }
    @Test fun selectingWenku8OrItsParentFindsTheDocumentedSavesDirectory() {
        val calls = ArrayList<String>()
        fun children(id: String): List<LegacyRecordDocument> {
            calls.add(id)
            return when(id) { "wenku8" -> listOf(folder("saves"), folder("custom")); "saves" -> records; else -> error("Unexpected directory") }
        }
        assertSame(records, LegacyRecordFolder.locate(listOf(folder("saves")), ::children))
        assertEquals(listOf("saves"), calls)
        calls.clear()
        assertSame(records, LegacyRecordFolder.locate(listOf(folder("wenku8"), folder("other")), ::children))
        assertEquals(listOf("wenku8", "saves"), calls)
        assertFalse(LegacyRecordFolder.names.contains("cert.wk8"))
    }
    @Test fun unrelatedDirectoryReturnsActionableErrorWithoutRecursion() {
        try {
            LegacyRecordFolder.locate(listOf(folder("unrelated"))) { error("Must not crawl") }
            fail("Expected missing records")
        } catch (e: LegacyRecordException) {
            assertEquals("legacy_empty", e.code)
            assertTrue(e.message!!.contains("saves"))
        }
    }
}
