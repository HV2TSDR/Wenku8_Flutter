package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.Test

class BookFolderIndexTest {
    @Test fun recursiveBooksAreStableSortedAndDeduplicated() {
        val root = listOf(FolderBookNode("dir", "分卷", true), FolderBookNode("b", "B.MOBI", false), FolderBookNode("pic", "cover.jpg", false))
        val nested = listOf(FolderBookNode("b", "B.MOBI", false), FolderBookNode("a", "A.epub", false), FolderBookNode("root", "循环", true), FolderBookNode("z", "合集.zip", false))
        val result = BookFolderIndex.collect("root") { if (it == "root") root else nested }
        assertEquals(listOf("b", "a", "z"), result.books.map { it.id })
        assertTrue(result.warnings.isEmpty())
    }
    @Test fun unreadableSubfolderDoesNotDiscardHealthyBooks() {
        val result = BookFolderIndex.collect("root") { if (it == "denied") throw SecurityException()
            else listOf(FolderBookNode("a", "A.txt", false), FolderBookNode("denied", "受限文件夹", true)) }
        assertEquals("A.txt", result.books.single().name)
        assertTrue(result.warnings.single().contains("受限文件夹"))
    }
    @Test fun revokedRootFailsInsteadOfPretendingTheLibraryIsEmpty() {
        assertThrows(SecurityException::class.java) { BookFolderIndex.collect("root") { throw SecurityException() } }
    }
    @Test fun oversizedTreeHasAnExplicitPartialScanNotice() {
        val result = BookFolderIndex.collect("root", maxDocuments = 2) {
            List(4) { FolderBookNode("$it", "$it.epub", false) }
        }
        assertEquals(2, result.books.size)
        assertTrue(result.warnings.single().contains("文件过多"))
    }
    @Test fun revisionsTrackSizeAndModificationWithoutReadingEveryOriginal() {
        val original = FolderBookNode("one", "one.epub", false, 100, 20)
        assertNotEquals(original.revision, original.copy(size = 110).revision)
        assertNotEquals(original.revision, original.copy(modified = 21).revision)
        assertEquals(original.revision, original.copy().revision)
    }
    @Test fun chosenFormatsFilterBeforePublishingCandidatesWithoutSkippingSubfolders() {
        val visited = mutableListOf<String>()
        val result = BookFolderIndex.collect("root", extensions = setOf("epub")) {
            visited.add(it)
            if (it == "root") listOf(FolderBookNode("dir", "分卷", true), FolderBookNode("t", "笔记.txt", false))
            else listOf(FolderBookNode("e", "第一卷.EPUB", false), FolderBookNode("m", "第二卷.mobi", false))
        }
        assertEquals(listOf("root", "dir"), visited)
        assertEquals(listOf("e"), result.books.map { it.id })
        assertTrue(result.warnings.isEmpty())
    }
}
