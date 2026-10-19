package org.mewx.wenku8_flutter

import java.io.File
import java.io.InputStream
import java.net.URI
import java.util.Base64
import java.util.zip.ZipFile
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.TextNode
import org.commonmark.parser.Parser
import org.commonmark.renderer.html.HtmlRenderer

internal class BookMarkupImport(private val root: File,
    private val pdf: ((File, BookEpubWriter) -> Unit)? = null) {
    fun convert(name: String, source: File, resource: ((String) -> InputStream?)? = null): Map<String, String> {
        val work = File.createTempFile("document-", ".work", root).apply { check(delete() && mkdir()) }
        val output = File.createTempFile("import-", ".source", root)
        try {
            require(source.length() <= BookArchiveImport.limit(name)) { "文件超过导入大小限制" }
            val writer = BookEpubWriter(work, name.substringBeforeLast('.'))
            when (name.substringAfterLast('.').lowercase()) {
                "fb2" -> fb2(source, writer, work)
                "docx" -> docx(source, writer)
                "html", "htm", "xhtml" -> {
                    var tags = 0
                    source.inputStream().use { input ->
                        val buffer = ByteArray(65536)
                        while (true) { val n = input.read(buffer); if (n < 0) break
                            for (i in 0 until n) if (buffer[i] == 60.toByte()) tags++
                            require(tags <= 200000) { "HTML 结构过于复杂，请转换为 EPUB 后导入" }
                        }
                    }
                    html(Jsoup.parse(source, null), writer, resource)
                }
                "md", "markdown" -> {
                    val normalized = File(work, "decoded.txt")
                    BookTextDecoder.normalize(source, normalized, "auto")
                    val parser = Parser.builder().build()
                    val renderer = HtmlRenderer.builder().escapeHtml(true).sanitizeUrls(true).build()
                    normalized.bufferedReader().use { reader ->
                        val chunk = StringBuilder()
                        fun flush() { if (chunk.isNotEmpty()) { html(Jsoup.parse(renderer.render(parser.parse(chunk.toString()))), writer, resource); chunk.setLength(0) } }
                        reader.forEachLine { line ->
                            var at = 0
                            while (at < line.length) {
                                var end = minOf(line.length, at + 4000)
                                if (end < line.length && line[end - 1].isHighSurrogate()) end--
                                chunk.append(line, at, end); at = end
                                if (chunk.length >= 200000) flush()
                            }
                            chunk.append('\n')
                            if (line.isBlank() && chunk.length >= 100000) flush()
                        }
                        flush()
                    }
                }
                "rtf" -> BookRtfImport.read(source, writer)
                "pdf" -> (pdf ?: error("PDF 引擎不可用，请安装完整版本"))(source, writer)
                else -> error("不支持的文档格式")
            }
            writer.write(output)
            return mapOf("name" to name.substringBeforeLast('.') + ".epub", "path" to output.path)
        } catch (error: Exception) { output.delete(); throw error }
        finally { work.deleteRecursively() }
    }
    private fun xml(input: InputStream, handler: DefaultHandler) {
        val factory = SAXParserFactory.newInstance().apply { isNamespaceAware = true }
        // Local book content is never allowed to load a DTD or external entity.
        val reader = factory.newSAXParser().xmlReader
        reader.setFeature("http://xml.org/sax/features/external-general-entities", false)
        reader.setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        reader.setProperty("http://xml.org/sax/properties/lexical-handler", object : org.xml.sax.ext.DefaultHandler2() {
            override fun startDTD(name: String?, publicId: String?, systemId: String?) {
                throw org.xml.sax.SAXException("不支持包含 DTD 或实体定义的文档")
            }
        })
        reader.entityResolver = org.xml.sax.EntityResolver { _, _ -> org.xml.sax.InputSource(java.io.StringReader("")) }
        reader.contentHandler = handler
        reader.parse(org.xml.sax.InputSource(input))
    }
    private fun html(document: org.jsoup.nodes.Document, writer: BookEpubWriter, resource: ((String) -> InputStream?)?) {
        document.title().trim().takeIf { it.isNotEmpty() }?.let { writer.title = it.take(2048) }
        writer.author = document.selectFirst("meta[name=author]")?.attr("content")?.take(2048) ?: ""
        document.select("script,style,nav,noscript,iframe,object").remove()
        val paragraph = StringBuilder()
        fun flush() { writer.text(paragraph.toString().trim()); paragraph.setLength(0) }
        fun visit(node: org.jsoup.nodes.Node, depth: Int = 0) {
            require(depth <= 256) { "HTML 嵌套层级过深" }
            if (node is TextNode) {
                val value = node.wholeText; var at = 0
                while (at < value.length) {
                    var end = minOf(value.length, at + 4000)
                    if (end < value.length && value[end - 1].isHighSurrogate()) end--
                    paragraph.append(value, at, end); at = end
                    if (paragraph.length >= 4000) flush()
                }
                return
            }
            if (node !is Element) return
            if (node.tagName().matches(Regex("h[1-6]"))) { flush(); writer.heading(node.text()); return }
            if (node.tagName() == "img") {
                flush(); val src = node.attr("src")
                val style = node.attr("style") + listOf("width", "height").joinToString("") { key ->
                    val value = node.attr(key)
                    if (value.matches(Regex("\\d+(\\.\\d+)?%?"))) ";$key:$value${if (value.endsWith('%')) "" else "px"}" else ""
                }
                if (src.startsWith("data:image/") && src.contains(";base64,")) {
                    require(src.length <= 12 * 1024 * 1024) { "内嵌图片超过大小限制" }
                    val type = src.substringAfter("data:").substringBefore(';')
                    val key = writer.inlineResourceKey()
                    Base64.getMimeDecoder().decode(src.substringAfter(',')).inputStream().use { writer.resource(key, type, it) }
                    writer.image(key, style)
                } else if (resource != null && !src.contains(":") && !src.startsWith('/')) {
                    resource(src)?.use { writer.resource(src, src.substringAfterLast('.'), it); writer.image(src, style) }
                }
                return
            }
            val block = node.isBlock || node.tagName() == "br"
            if (block) flush()
            node.childNodes().forEach { visit(it, depth + 1) }
            if (block) flush()
        }
        visit(document.body()); flush()
    }
    private fun fb2(source: File, writer: BookEpubWriter, work: File) {
        var body = false; var title = false; var p = false; var meta = ""; var binary: File? = null
        var binaryKey = ""; var binaryType = ""; var encoded: java.io.Writer? = null; var binarySize = 0L
        val text = StringBuilder()
        fun flush() { if (title) writer.heading(text.toString()) else writer.text(text.toString()); text.setLength(0) }
        try {
            source.inputStream().use { input -> xml(input, object : DefaultHandler() {
                override fun startElement(uri: String?, local: String, q: String?, attributes: Attributes) {
                    when (local) {
                        "body" -> { body = true; writer.heading(attributes.getValue("name") ?: writer.title) }
                        "title" -> if (body) { flush(); title = true }
                        "p", "v", "subtitle" -> if (body) p = true
                        "book-title", "first-name", "last-name" -> if (!body) { meta = local; text.setLength(0) }
                        "image" -> {
                            val ref = (attributes.getValue("http://www.w3.org/1999/xlink", "href") ?: attributes.getValue("href") ?: "").removePrefix("#")
                            if (body) { flush(); writer.image(ref) } else if (writer.cover == null) writer.cover = ref
                        }
                        "binary" -> {
                            binaryKey = attributes.getValue("id") ?: ""
                            binaryType = attributes.getValue("content-type") ?: ""
                            binary = File(work, "binary.base64"); encoded = binary!!.bufferedWriter(); binarySize = 0
                        }
                    }
                }
                override fun characters(chars: CharArray, start: Int, length: Int) {
                    if (encoded != null) {
                        binarySize += length; require(binarySize <= 12L * 1024 * 1024) { "FB2 单张图片超过大小限制" }
                        encoded!!.write(chars, start, length)
                    } else if (body && (p || title) || meta.isNotEmpty()) {
                        text.append(chars, start, length)
                        if (body && !title && text.length >= 4000) flush()
                    }
                }
                override fun endElement(uri: String?, local: String, q: String?) {
                    when (local) {
                        "p", "v", "subtitle" -> if (body) { if (!title) flush(); p = false }
                        "title" -> if (body) { flush(); title = false }
                        "body" -> { flush(); body = false }
                        "book-title" -> if (meta == local) { writer.title = text.toString().trim().take(2048); meta = ""; text.setLength(0) }
                        "first-name", "last-name" -> if (meta == local) { writer.author = (writer.author + " " + text.toString().trim()).trim().take(2048); meta = ""; text.setLength(0) }
                        "binary" -> {
                            encoded?.close(); encoded = null
                            binary!!.inputStream().use { stream -> Base64.getMimeDecoder().wrap(stream).use { writer.resource(binaryKey, binaryType, it) } }
                            binary!!.delete(); binary = null
                        }
                    }
                }
            }) }
        } finally { encoded?.close(); binary?.delete() }
    }
    private fun docx(source: File, writer: BookEpubWriter) {
        ZipFile(source).use { zip ->
            val entries = zip.entries().toList(); var expanded = 0L
            require(entries.size <= 12000) { "DOCX 内文件过多" }
            for (entry in entries) {
                require(entry.size >= 0 && entry.size <= 40L * 1024 * 1024 && expanded + entry.size <= 1024L * 1024 * 1024) { "DOCX 解压后超过大小限制" }
                expanded += entry.size
            }
            val relations = mutableMapOf<String, String>()
            zip.getEntry("word/_rels/document.xml.rels")?.let { entry -> zip.getInputStream(entry).use { xml(it, object : DefaultHandler() {
                override fun startElement(uri: String?, local: String, q: String?, a: Attributes) {
                    if (local == "Relationship" && a.getValue("TargetMode") != "External") {
                        val target = a.getValue("Target") ?: return
                        val path = URI("https://local/word/document.xml").resolve(target).normalize()
                        if (path.host == "local" && path.scheme == "https") relations[a.getValue("Id") ?: ""] = path.path.removePrefix("/")
                    }
                }
            }) } }
            zip.getEntry("docProps/core.xml")?.let { entry -> zip.getInputStream(entry).use { xml(it, object : DefaultHandler() {
                var field = ""; val value = StringBuilder()
                override fun startElement(uri: String?, local: String, q: String?, a: Attributes) { if (local in listOf("title", "creator")) { field = local; value.setLength(0) } }
                override fun characters(c: CharArray, start: Int, length: Int) { if (field.isNotEmpty() && value.length < 2048) value.append(c, start, minOf(length, 2048 - value.length)) }
                override fun endElement(uri: String?, local: String, q: String?) { if (local == field) { if (field == "title" && value.isNotBlank()) writer.title = value.toString(); if (field == "creator") writer.author = value.toString(); field = "" } }
            }) } }
            val entry = zip.getEntry("word/document.xml") ?: error("DOCX 缺少正文，或文件已加密")
            zip.getInputStream(entry).use { xml(it, object : DefaultHandler() {
                var inText = false; var heading = false; var width = ""; val text = StringBuilder()
                fun flush() { if (heading) writer.heading(text.toString()) else writer.text(text.toString()); text.setLength(0) }
                override fun startElement(uri: String?, local: String, q: String?, a: Attributes) {
                    fun attr(name: String) = a.getValue("http://schemas.openxmlformats.org/wordprocessingml/2006/main", name) ?: a.getValue("w:$name")
                    when (local) {
                        "p" -> { heading = false; width = "" }
                        "pStyle" -> heading = (attr("val") ?: "").contains(Regex("heading|标题", RegexOption.IGNORE_CASE))
                        "t" -> inText = true
                        "tab" -> text.append(' ')
                        "br" -> flush()
                        "extent" -> a.getValue("cx")?.toLongOrNull()?.let { width = "width:${it / 9525.0}px" }
                        "blip" -> {
                            val id = a.getValue("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "embed") ?: a.getValue("r:embed")
                            val path = relations[id]
                            if (path != null) zip.getEntry(path)?.let { image ->
                                flush(); zip.getInputStream(image).use { writer.resource(path, path.substringAfterLast('.'), it) }; writer.image(path, width)
                            }
                        }
                    }
                }
                override fun characters(c: CharArray, start: Int, length: Int) { if (inText) { text.append(c, start, length); if (text.length >= 4000 && !heading) flush() } }
                override fun endElement(uri: String?, local: String, q: String?) { if (local == "t") inText = false; if (local == "p") flush() }
            }) }
        }
    }
}
