package org.mewx.wenku8_flutter

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.Manifest
import android.content.pm.PackageManager
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Persisted read-only SAF tree. Document URIs never cross the Flutter channel. */
class BookFolderScanner(private val context: Context) {
    private val resolver = context.contentResolver
    private val preferences = context.getSharedPreferences("book_scan_folders", 0)
    private val entries = mutableMapOf<String, FolderBookNode>()
    private var importedIndex: JSONObject? = null
    private var pendingMarks = 0
    private fun allStorage() = preferences.getBoolean("all", false)
    fun canReadAll(): Boolean = if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    fun selectAll(): Map<String, Any> {
        check(canReadAll()) { "请先允许扫描共享存储，或选择指定文件夹" }
        check(preferences.edit().putBoolean("all", true).commit()) { "扫描设置保存失败" }
        entries.clear()
        importedIndex = null
        return info()!!
    }
    private fun tree(): Uri? = preferences.getString("tree", null)?.let(Uri::parse)
    private fun saved(): JSONObject = try { JSONObject(preferences.getString("imported", "{}")!!) }
        catch (_: Exception) { JSONObject() }

    fun info(): Map<String, Any>? {
        if (allStorage()) return mapOf("name" to "全部共享存储", "all" to true,
            "automatic" to preferences.getBoolean("automatic", false), "readable" to canReadAll())
        val uri = tree() ?: return null
        val readable = resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
        return mapOf("name" to preferences.getString("name", "书籍文件夹")!!,
            "automatic" to preferences.getBoolean("automatic", false), "readable" to readable)
    }

    fun select(uri: Uri, flags: Int): Map<String, Any> {
        require(DocumentsContract.isTreeUri(uri) && flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
            "请选择一个可读取的书籍文件夹"
        }
        val old = tree()
        val alreadyGranted = resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
        resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        var committed = false
        try {
            val document = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            val name = resolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: "书籍文件夹"
            val edit = preferences.edit().putBoolean("all", false).putString("tree", uri.toString()).putString("name", name)
            if (old != uri) edit.remove("imported")
            check(edit.commit()) { "文件夹设置保存失败" }
            committed = true
            entries.clear()
            importedIndex = null
            if (old != null && old != uri) try {
                resolver.releasePersistableUriPermission(old, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) { }
            return info()!!
        } catch (error: Exception) {
            if (!committed && !alreadyGranted) try {
                resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) { }
            throw error
        }
    }

    fun setAutomatic(value: Boolean) {
        check(preferences.edit().putBoolean("automatic", value).commit()) { "扫描设置保存失败" }
    }

    fun formats(): Set<String> = preferences.getStringSet("formats", null)?.toSet() ?: BookArchiveImport.extensions
    fun setFormats(extensions: List<String>) {
        val chosen = extensions.map { it.lowercase() }.toSet()
        require(chosen.isNotEmpty() && BookArchiveImport.extensions.containsAll(chosen)) { "请至少选择一种支持的格式" }
        check(preferences.edit().putStringSet("formats", chosen).commit()) { "扫描格式保存失败" }
    }

    fun disconnect() {
        val uri = tree()
        check(preferences.edit().clear().commit()) { "文件夹设置保存失败" }
        entries.clear()
        importedIndex = null
        if (uri != null) try {
            resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) { }
    }

    private fun children(tree: Uri, parent: String): List<FolderBookNode> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        return resolver.query(uri, columns, null, null, null)?.use { cursor ->
            val items = mutableListOf<FolderBookNode>()
            while (cursor.moveToNext()) items.add(FolderBookNode(
                id = cursor.getString(0), name = cursor.getString(1) ?: "未命名书籍",
                directory = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR,
                size = if (cursor.isNull(3)) -1 else cursor.getLong(3),
                modified = if (cursor.isNull(4)) 0 else cursor.getLong(4)))
            items
        } ?: error("文件夹暂时不可读取")
    }

    fun scan(): Map<String, Any> {
        finish()
        val all = allStorage()
        val uri = if (all) null else tree() ?: error("请先选择书籍文件夹")
        check(info()?.get("readable") == true) { "文件夹访问权限已失效，请重新选择文件夹" }
        entries.clear()
        val formats = formats()
        val index = if (all) sharedStorageIndex(formats) else BookFolderIndex.collect(DocumentsContract.getTreeDocumentId(uri!!), extensions = formats) { children(uri, it) }
        val imported = saved()
        importedIndex = imported
        var unchanged = 0
        val books = mutableListOf<Map<String, Any>>()
        for (book in index.books) {
            if (book.modified > 0 && imported.optString(sourceKey(book)) == book.revision) { unchanged++; continue }
            val token = UUID.randomUUID().toString()
            entries[token] = book
            books.add(mapOf("token" to token, "name" to book.name, "size" to book.size,
                "folder" to book.id.substringBeforeLast('/', "").substringAfter(':').takeLast(240)))
        }
        return mapOf("books" to books, "unchanged" to unchanged,
            "total" to index.books.size, "warnings" to index.warnings)
    }

    fun stage(token: String, root: File, copy: (Uri, File, Long) -> Unit): Map<String, String> {
        val node = entries[token] ?: error("扫描结果已过期，请重新扫描")
        val uri = if (allStorage()) null else tree() ?: error("请先选择书籍文件夹")
        val source = if (allStorage()) {
            check(canReadAll()) { "共享存储权限已关闭" }
            Uri.fromFile(File(node.id))
        } else DocumentsContract.buildDocumentUriUsingTree(uri!!, node.id)
        require(node.size <= BookArchiveImport.limit(node.name)) { "书籍文件过大" }
        val target = File.createTempFile("import-", ".source", root)
        try {
            copy(source, target, BookArchiveImport.limit(node.name))
            return mapOf("name" to node.name, "path" to target.path)
        } catch (error: Exception) { target.delete(); throw error }
    }

    fun markImported(token: String) {
        val node = entries[token] ?: error("扫描结果已过期，下次扫描会再次检查")
        val imported = importedIndex ?: saved().also { importedIndex = it }
        imported.put(sourceKey(node), node.revision)
        // Parse the saved index once and checkpoint every 16 successful books,
        // rather than rewriting N growing JSON objects for N imports.
        pendingMarks++
        if (pendingMarks >= 16) finish()
    }
    fun finish() {
        if (pendingMarks == 0) return
        check(preferences.edit().putString("imported", importedIndex.toString()).commit()) { "扫描记录保存失败" }
        pendingMarks = 0
    }
    private fun sourceKey(node: FolderBookNode): String = if (allStorage()) "all:${node.id}" else "${tree()}:${node.id}"

    private fun sharedStorageIndex(formats: Set<String>): FolderBookIndex {
        val roots = if (Build.VERSION.SDK_INT >= 30)
            context.getSystemService(StorageManager::class.java).storageVolumes.mapNotNull { it.directory }
        else listOf(Environment.getExternalStorageDirectory())
        val books = mutableListOf<FolderBookNode>()
        val warnings = mutableListOf<String>()
        for (root in roots.distinctBy { it.absolutePath }) {
            val base = root.canonicalFile
            if (!base.isDirectory) continue
            val index = try { BookFolderIndex.collect(base.path, maxDocuments = 200000, extensions = formats) { path ->
                (File(path).listFiles() ?: error("文件夹暂时不可读取")).mapNotNull { file ->
                    // Shared documents only: no app-private Android trees,
                    // hidden caches or symlink traversal outside a volume.
                    if (file.name.startsWith(".") || file.parentFile == base && file.name == "Android") null
                    else if (file.isDirectory) {
                        if (file.canonicalFile.path != file.absolutePath) null
                        else FolderBookNode(file.absolutePath, file.name, true)
                    } else if (file.name.substringAfterLast('.').lowercase() !in formats) null
                    else if (!file.canonicalFile.path.startsWith(base.path + File.separator)) null
                    else FolderBookNode(file.absolutePath, file.name, false, file.length(), file.lastModified())
                }
            } } catch (_: Exception) { warnings.add("${base.name}：共享存储暂时不可读取"); continue }
            books.addAll(index.books); warnings.addAll(index.warnings)
        }
        return FolderBookIndex(books, warnings)
    }
}
