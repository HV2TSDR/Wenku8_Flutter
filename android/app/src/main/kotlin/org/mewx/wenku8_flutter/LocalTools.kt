package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Intent
import android.content.ClipData
import android.net.Uri
import android.provider.DocumentsContract
import android.os.Build
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executors
import java.io.File
import androidx.core.content.FileProvider

/** Explicit document/folder/share actions; never touches the Wenku8 bridge/session. */
class LocalTools(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val io = Executors.newSingleThreadExecutor()
    private data class Pending(val result: MethodChannel.Result, val export: String?, val legacy: Boolean = false, val image: ByteArray? = null)
    private var pending: Pending? = null
    private var pendingShare: MethodChannel.Result? = null
    private var closed = false
    companion object {
        private const val REQUEST = 8019
        private const val MAX_BYTES = 4 * 1024 * 1024
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getKeepScreenOn" -> result.success(
                activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
            )
            "keepScreenOn" -> {
                if (call.arguments == true) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "shareText" -> {
                val text = call.argument<String>("text") ?: ""
                if (text.isBlank() || text.length > 10000) {
                    result.error("input", "Invalid share text", null)
                } else try {
                    activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                    }, "分享图书"))
                    result.success(null)
                } catch (_: Exception) { result.error("share", "Share sheet did not open", null) }
            }
            "shareImage" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (pendingShare != null || pending != null || closed) {
                    result.error("busy", "A document or share operation is already active", null)
                    return
                }
                if (!QuoteCardImage.valid(bytes)) {
                    result.error("input", "Invalid excerpt image", null)
                    return
                }
                pendingShare = result
                io.execute {
                    try {
                        val directory = File(activity.cacheDir, "quote_cards").apply { mkdirs() }
                        directory.listFiles()?.filter { it.isFile && it.extension == "png" && it.lastModified() < System.currentTimeMillis() - 24 * 60 * 60 * 1000 }
                            ?.forEach { it.delete() }
                        val file = File.createTempFile("excerpt-", ".png", directory)
                        file.writeBytes(bytes!!)
                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                        activity.runOnUiThread {
                            if (closed || pendingShare !== result) return@runOnUiThread
                            pendingShare = null
                            try {
                                val intent = Intent(Intent.ACTION_SEND).apply {
                                    type = "image/png"
                                    putExtra(Intent.EXTRA_STREAM, uri)
                                    clipData = ClipData.newUri(activity.contentResolver, "阅读摘录", uri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                activity.startActivity(Intent.createChooser(intent, "分享摘录"))
                                result.success(null)
                            } catch (_: Exception) { result.error("share", "Share sheet did not open", null) }
                        }
                    } catch (_: Exception) {
                        activity.runOnUiThread {
                            if (!closed && pendingShare === result) {
                                pendingShare = null
                                result.error("share", "Image could not be prepared", null)
                            }
                        }
                    }
                }
            }
            "saveBookImage", "exportImage", "exportBackup", "importBackup", "importLegacyData" -> {
                if (pending != null || pendingShare != null || closed) {
                    result.error("busy", "A document operation is already active", null)
                    return
                }
                val text = if (call.method == "exportBackup") call.argument<String>("text") else null
                val legacy = call.method == "importLegacyData"
                val bookImage = if (call.method == "saveBookImage") try {
                    BookImageStore.image(call.argument<ByteArray>("bytes"), call.argument<String>("name"))
                } catch (_: Exception) { result.error("image", "图片格式或大小无效", null); return } else null
                if (bookImage != null && Build.VERSION.SDK_INT >= 29) {
                    pendingShare = result
                    io.execute {
                        var error: Exception? = null
                        try { BookImageStore.save(activity, bookImage) } catch (failure: Exception) { error = failure }
                        activity.runOnUiThread {
                            if (!closed && pendingShare === result) {
                                pendingShare = null
                                if (error == null) result.success(true) else result.error("image", "图片保存失败，请检查可用空间后重试", null)
                            }
                        }
                    }
                    return
                }
                val image = bookImage?.bytes ?: if (call.method == "exportImage") call.argument<ByteArray>("bytes") else null
                if (call.method == "exportImage" && !QuoteCardImage.valid(image)) {
                    result.error("input", "Invalid excerpt image", null)
                    return
                }
                if (call.method == "exportBackup" && (text == null || text.toByteArray(Charsets.UTF_8).size > MAX_BYTES)) {
                    result.error("size", "Backup exceeds the document limit", null)
                    return
                }
                val intent = Intent(if (legacy) Intent.ACTION_OPEN_DOCUMENT_TREE else if (text == null && image == null) Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    if (!legacy) {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = bookImage?.mime ?: if (image != null) "image/png" else if (text == null) "*/*" else "application/json"
                        if (text == null && image == null) putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream"))
                        else putExtra(Intent.EXTRA_TITLE, bookImage?.name ?: if (image != null) QuoteCardImage.fileName(call.argument<String>("name")) else call.argument<String>("name") ?: "wenku8-backup.json")
                    }
                }
                pending = Pending(result, text, legacy, image)
                try {
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(if (legacy) Intent.createChooser(intent, "选择旧版记录目录") else intent, REQUEST)
                } catch (_: Exception) {
                    pending = null
                    result.error("picker", "Document picker could not open", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        val operation = pending ?: return true
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) {
            pending = null
            operation.result.success(if (operation.export == null && operation.image == null) null else false)
            return true
        }
        io.execute {
            try {
                val response: Any = if (operation.legacy) {
                    readLegacyTree(uri)
                } else if (operation.export != null || operation.image != null) {
                    activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        output.write(operation.image ?: operation.export!!.toByteArray(Charsets.UTF_8))
                        output.flush()
                    } ?: throw IllegalStateException("Document is not writable")
                    true
                } else {
                    val bytes = ByteArrayOutputStream()
                    activity.contentResolver.openInputStream(uri)?.use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (bytes.size() + count > MAX_BYTES) throw IllegalArgumentException("Document is too large")
                            bytes.write(buffer, 0, count)
                        }
                    } ?: throw IllegalStateException("Document is not readable")
                    Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
                }
                activity.runOnUiThread {
                    if (!closed) {
                        pending = null
                        operation.result.success(response)
                    }
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    if (!closed) {
                        pending = null
                        if (operation.legacy) {
                            operation.result.error(
                                if (error is LegacyRecordException) error.code else "legacy_access",
                                if (error is LegacyRecordException) error.message else "无法读取所选目录，请重新选择并允许文件访问",
                                null,
                            )
                        } else operation.result.error("document", "Document read or write failed", null)
                    }
                }
            }
        }
        return true
    }

    /** Only documented record/index files from the explicitly selected tree.
     * Never read cert.wk8, account files, images or arbitrary nested folders. */
    private fun readLegacyTree(tree: Uri): Map<String, Any> {
        fun children(id: String): List<LegacyRecordDocument> {
            val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            return activity.contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
                val records = ArrayList<LegacyRecordDocument>()
                while (cursor.moveToNext()) {
                    check(records.size < 10000) { "Folder too large" }
                    records.add(LegacyRecordDocument(cursor.getString(0), cursor.getString(1),
                        cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR, cursor.getLong(3)))
                }
                records
            } ?: throw IllegalStateException("Folder is not readable")
        }
        val root = children(DocumentsContract.getTreeDocumentId(tree))
        val saves = LegacyRecordFolder.locate(root, ::children)
        val records = saves.filter { !it.directory && it.name in LegacyRecordFolder.names }
        if (records.isEmpty()) throw LegacyRecordException("legacy_empty", "此目录没有旧版书架或阅读记录，请选择正确的 saves 目录")
        val indices = saves.firstOrNull { it.directory && it.name == "intro" }?.let { children(it.id) }
            ?.filter { !it.directory && Regex("[1-9][0-9]{0,9}-volume\\.xml").matches(it.name) } ?: emptyList()
        val output = LinkedHashMap<String, Any>()
        var total = 0
        var skipped = 0
        for (document in records + indices) {
            val content = activity.contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, document.id))?.use { input ->
                val bytes = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                var oversized = false
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (bytes.size() + count > MAX_BYTES || total + bytes.size() + count > 8 * 1024 * 1024) {
                        if (document in records) throw LegacyRecordException("legacy_size", "旧版记录超过导入上限：单文件 4 MiB，总计 8 MiB")
                        skipped++
                        oversized = true
                        break
                    }
                    bytes.write(buffer, 0, count)
                }
                if (oversized) null else bytes.toByteArray()
            } ?: continue
            try {
                val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(content)).toString()
                total += content.size
                output[document.name] = mapOf("text" to text, "modifiedAt" to document.modified)
            } catch (_: Exception) { skipped++ }
        }
        if (records.none { output.containsKey(it.name) }) throw LegacyRecordException("legacy_encoding", "旧版记录无法解码为 UTF-8，请选择旧版文库原始的 saves 目录")
        return mapOf("documents" to output, "skippedFiles" to skipped)
    }

    fun close() {
        closed = true
        pending?.result?.error("closed", "Activity closed", null)
        pending = null
        pendingShare?.error("closed", "Activity closed", null)
        pendingShare = null
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        io.shutdown()
    }
}
