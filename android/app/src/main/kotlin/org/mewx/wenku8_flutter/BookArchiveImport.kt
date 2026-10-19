package org.mewx.wenku8_flutter

import java.io.File
import java.io.InputStream
import java.io.IOException
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipException
import java.util.zip.ZipOutputStream

internal object MobiConverter {
    init { System.loadLibrary("wenku_mobi") }
    external fun exportParts(input: String, output: String): Int
}

/** App-private staging only; archive names are never filesystem destinations. */
internal class BookArchiveImport(
    private val root: File,
    private val exportMobi: (String, String) -> Int = { input, output -> MobiConverter.exportParts(input, output) },
) {
    var documents: BookMarkupImport = BookMarkupImport(root)
    companion object {
        const val MAX_ARCHIVE = 512L * 1024 * 1024
        private const val MAX_EXPANDED = 1024L * 1024 * 1024
        private val kindle = setOf("mobi", "azw", "azw3", "prc")
        private val markup = setOf("fb2", "docx", "html", "htm", "xhtml", "md", "markdown", "rtf", "pdf")
        val extensions = kindle + markup + setOf("txt", "epub", "zip")
        fun supported(name: String) = name.substringAfterLast('.').lowercase() in extensions
        fun limit(name: String) = when (name.substringAfterLast('.').lowercase()) {
            "txt", "fb2", "rtf" -> BookTextDecoder.MAX_TEXT
            "html", "htm", "xhtml", "md", "markdown" -> 32L * 1024 * 1024
            "zip" -> MAX_ARCHIVE
            in kindle -> 256L * 1024 * 1024
            else -> 512L * 1024 * 1024
        }
    }

    fun prepare(name: String, source: File): List<Map<String, String>> {
        require(supported(name)) { "请选择支持的电子书或文档格式" }
        require(source.length() > 0) { "文件为空，请重新下载原书" }
        require(source.length() <= limit(name)) { "单个 ${name.substringAfterLast('.').uppercase()} 不能超过 ${limit(name) / (1024 * 1024)} MiB" }
        return when (name.substringAfterLast('.').lowercase()) {
            "zip" -> unpack(source)
            in kindle -> listOf(convert(name, source))
            in markup -> listOf(documents.convert(name, source))
            else -> listOf(mapOf("name" to name, "path" to source.path))
        }
    }

    private fun temporary() = File.createTempFile("import-", ".source", root)

    private fun unpack(source: File): List<Map<String, String>> {
        val prepared = mutableListOf<Map<String, String>>()
        try {
            val opened = try { ZipFile(source, Charsets.UTF_8) }
                catch (_: ZipException) { ZipFile(source, charset("GB18030")) }
            opened.use { archive ->
                val entries = archive.entries().toList()
                require(entries.size <= 12000) { "压缩包文件过多" }
                var declared = 0L
                for (entry in entries) {
                    require(!entry.name.startsWith('/') && !entry.name.contains('\\') &&
                        !entry.name.split('/').contains("..")) { "压缩包包含无效路径" }
                    require(entry.size >= 0 && entry.size <= MAX_EXPANDED - declared) { "压缩包解压后超过 1 GiB" }
                    declared += entry.size
                }
                val books = entries.filter { !it.isDirectory &&
                    !it.name.split('/').any { part -> part.startsWith('.') || part == "__MACOSX" } &&
                    supported(it.name) && !it.name.lowercase().endsWith(".zip") }
                require(books.isNotEmpty()) { "压缩包内没有支持的书籍或文档" }
                require(books.size <= 200) { "一个压缩包最多导入 200 本书" }
                var expanded = 0L
                for (entry in books) {
                    val name = entry.name.substringAfterLast('/')
                    var staged: File? = null
                    try {
                        require(entry.size in 1..limit(name)) { "书籍为空或超过大小限制" }
                        val target = temporary().also { staged = it }
                        archive.getInputStream(entry).use { input ->
                            expanded += copy(input, target, minOf(limit(name), MAX_EXPANDED - expanded), entry.crc)
                        }
                        prepared += if (name.substringAfterLast('.').lowercase() in kindle) {
                            try { convert(name, target) } finally { target.delete() }
                        } else if (name.substringAfterLast('.').lowercase() in markup) {
                            try { documents.convert(name, target) { href ->
                                val resolved = java.net.URI("https://local/${entry.name}").resolve(href).normalize()
                                if (resolved.scheme != "https" || resolved.host != "local") null
                                else archive.getEntry(resolved.path.removePrefix("/"))?.let { media ->
                                    require(media.size in 0..8L * 1024 * 1024) { "压缩包中的图片超过 8 MiB" }
                                    archive.getInputStream(media)
                                }
                            } } finally { target.delete() }
                        } else mapOf("name" to name, "path" to target.path)
                    } catch (failure: Exception) {
                        staged?.delete()
                        prepared += mapOf("name" to name, "error" to importMessage(failure))
                    }
                }
            }
            return prepared
        } catch (failure: Exception) {
            prepared.mapNotNull { it["path"] }.forEach { File(it).delete() }
            throw IllegalArgumentException(importMessage(failure), failure)
        }
    }

    private fun importMessage(failure: Exception) = when (failure) {
        is ZipException -> "ZIP 已损坏、已加密或使用了不支持的压缩方式"
        is IOException -> "无法读取压缩包中的书籍，请检查文件与剩余空间"
        else -> failure.message ?: "无法读取压缩包中的书籍"
    }

    private fun copy(input: InputStream, target: File, max: Long, crc: Long): Long {
        var size = 0L
        val checksum = CRC32()
        target.outputStream().use { output ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                size += read
                require(size <= max) { "书籍解压后超过大小限制" }
                output.write(buffer, 0, read)
                checksum.update(buffer, 0, read)
            }
        }
        require(crc < 0 || checksum.value == crc) { "压缩包中的书籍校验失败，请重新下载" }
        return size
    }

    private fun convert(name: String, source: File): Map<String, String> {
        val work = File.createTempFile("mobi-", ".work", root).apply {
            check(delete() && mkdir()) { "无法创建 MOBI 转换目录" }
        }
        val output = temporary()
        try {
            val content = File(work, "OEBPS").apply { check(mkdir()) }
            val status = try { exportMobi(source.path, content.path) }
                catch (_: LinkageError) { error("MOBI 引擎无法加载，请重新安装完整版本") }
            require(status == 0) { when (status) {
                1 -> "不支持受 DRM 保护的 Kindle 电子书"
                3 -> "MOBI 正文或资源超过大小限制"
                4 -> "MOBI 转换文件写入失败"
                else -> "MOBI 文件损坏或格式不受支持"
            } }
            require(File(content, "content.opf").isFile) { "MOBI 缺少有效目录" }
            val meta = File(work, "META-INF").apply { check(mkdir()) }
            File(meta, "container.xml").writeText("""<?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            ZipOutputStream(output.outputStream()).use { zip ->
                val mime = "application/epub+zip".toByteArray()
                val mimeEntry = ZipEntry("mimetype").apply {
                    time = 0; method = ZipEntry.STORED; size = mime.size.toLong()
                    compressedSize = size; crc = CRC32().apply { update(mime) }.value
                }
                zip.putNextEntry(mimeEntry); zip.write(mime); zip.closeEntry()
                for (file in work.walkTopDown().filter { it.isFile }.sortedBy { it.relativeTo(work).invariantSeparatorsPath }) {
                    val entry = ZipEntry(file.relativeTo(work).invariantSeparatorsPath).apply { time = 0 }
                    zip.putNextEntry(entry)
                    file.inputStream().use { it.copyTo(zip, 64 * 1024) }
                    zip.closeEntry()
                }
            }
            require(output.length() <= limit("book.epub")) { "转换后的 EPUB 超过 512 MiB" }
            return mapOf("name" to name.substringBeforeLast('.') + ".epub", "path" to output.path)
        } catch (failure: Exception) {
            output.delete()
            throw failure
        } finally { work.deleteRecursively() }
    }
}
