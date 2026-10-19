package org.mewx.wenku8_flutter

import java.util.ArrayDeque

data class FolderBookNode(val id: String, val name: String, val directory: Boolean,
    val size: Long = -1, val modified: Long = 0) {
    val revision: String get() = "$size:$modified"
}
data class FolderBookIndex(val books: List<FolderBookNode>, val warnings: List<String>)

/** Metadata only. A single unreadable subfolder cannot discard healthy books. */
object BookFolderIndex {
    fun collect(root: String, maxDocuments: Int = 20000, extensions: Set<String>? = null,
        children: (String) -> List<FolderBookNode>): FolderBookIndex {
        val queue = ArrayDeque<Pair<String, String>>()
        val visited = hashSetOf<String>()
        val books = mutableListOf<FolderBookNode>()
        val warnings = mutableListOf<String>()
        queue.add(root to "所选文件夹")
        var count = 0
        while (queue.isNotEmpty()) {
            val (parent, label) = queue.removeFirst()
            if (!visited.add(parent)) continue
            val entries = try { children(parent) } catch (error: SecurityException) {
                if (parent == root) throw error
                warnings.add("$label：无法读取，请检查文件夹权限"); continue
            } catch (error: Exception) {
                if (parent == root) throw error
                warnings.add("$label：读取失败，可稍后重新扫描"); continue
            }
            for (entry in entries.sortedBy { it.name.lowercase() }) {
                if (++count > maxDocuments) {
                    warnings.add("文件过多，请选择更小的书籍文件夹继续扫描")
                    return FolderBookIndex(books, warnings)
                }
                if (entry.directory) queue.add(entry.id to entry.name)
                else if (BookArchiveImport.supported(entry.name) &&
                    (extensions == null || entry.name.substringAfterLast('.').lowercase() in extensions) && visited.add(entry.id)) books.add(entry)
            }
        }
        return FolderBookIndex(books, warnings)
    }
}
