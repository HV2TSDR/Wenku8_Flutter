package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.After
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipFile
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class BookMarkupImportTest {
    private val root = Files.createTempDirectory("wenku-documents-").toFile()
    @After fun cleanup() { root.deleteRecursively() }
    private fun convert(name: String, text: String): Map<String, String> {
        val source = File(root, name).apply { writeText(text) }
        return BookArchiveImport(root).prepare(name, source).single()
    }
    private fun contents(value: Map<String, String>): String = ZipFile(value["path"]!!).use { zip ->
        zip.entries().toList().filter { it.name.matches(Regex("c\\d+\\.xhtml")) }
            .joinToString("\n") { zip.getInputStream(it).reader().readText() }
    }
    @Test fun htmlAndMarkdownKeepReadableTextAndSplitHeadings() {
        val html = convert("作品.html", "<html><head><title>作品名称</title><script>badScript()</script></head><body><h1>第一章</h1><p>中文 &amp; 正文。</p><h2>第二章</h2><p>继续阅读。</p></body></html>")
        val body = contents(html)
        assertTrue(body.contains("中文 &amp; 正文。")); assertTrue(body.contains("继续阅读。")); assertFalse(body.contains("badScript"))
        val md = convert("作品.md", "# 第一章\n\n**中文正文**。\n\n# 第二章\n\n继续阅读。")
        assertTrue(contents(md).contains("中文正文")); assertTrue(contents(md).contains("继续阅读"))
    }
    @Test fun fb2PreservesMetadataSectionsAndEmbeddedImage() {
        val book = convert("作品.fb2", """<?xml version="1.0"?><FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>作品标题</book-title><author><first-name>某位</first-name><last-name>作者</last-name></author><coverpage><image l:href="#cover"/></coverpage></title-info></description><body><section><title><p>第一章</p></title><p>第一段文字。</p><image l:href="#cover"/><p>图片后文字。</p></section><section><title><p>第二章</p></title><p>第二章正文。</p></section></body><binary id="cover" content-type="image/png">AQID</binary></FictionBook>""")
        val body = contents(book)
        assertTrue(body.indexOf("第一段") < body.indexOf("image-0.png")); assertTrue(body.indexOf("image-0.png") < body.indexOf("图片后"))
        ZipFile(book["path"]!!).use { zip ->
            assertArrayEquals(byteArrayOf(1,2,3), zip.getInputStream(zip.getEntry("image-0.png")).readBytes())
            val opf = zip.getInputStream(zip.getEntry("content.opf")).reader().readText()
            assertTrue(opf.contains("作品标题")); assertTrue(opf.contains("某位 作者")); assertTrue(opf.contains("cover-image"))
        }
    }
    @Test fun docxMaintainsParagraphAndImageOrder() {
        val source = File(root, "作品.docx")
        ZipOutputStream(source.outputStream()).use { zip ->
            for ((name, text) in mapOf(
                "word/_rels/document.xml.rels" to """<Relationships><Relationship Id="r1" Target="media/cover.png"/></Relationships>""",
                "word/document.xml" to """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="a"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章</w:t></w:r></w:p><w:p><w:r><w:t>图前正文。</w:t><a:blip r:embed="r1"/><w:t>图后正文。</w:t></w:r></w:p></w:body></w:document>""",
                "word/media/cover.png" to "image"
            )) { zip.putNextEntry(ZipEntry(name)); zip.write(text.toByteArray()); zip.closeEntry() }
        }
        val book = BookArchiveImport(root).prepare(source.name, source).single()
        val body = contents(book)
        assertTrue(body.indexOf("图前") < body.indexOf("image-0.png")); assertTrue(body.indexOf("image-0.png") < body.indexOf("图后"))
    }
    @Test fun rtfDecodesUnicodeAndSkipsFormattingDestinations() {
        val book = convert("作品.rtf", "{\\rtf1\\ansi\\ansicpg1252{\\fonttbl{\\f0 ignored;}}\\uc1\\u20013?\\u25991?\\par caf\\'e9\\par {\\*\\comment secret}正文}")
        val body = contents(book)
        assertTrue(body.contains("中文")); assertTrue(body.contains("café")); assertFalse(body.contains("ignored")); assertFalse(body.contains("secret"))
    }
    @Test fun archiveIncludesNewFormatsAndRelativeHtmlImages() {
        val source = File(root, "合集.zip")
        ZipOutputStream(source.outputStream()).use { zip ->
            for ((name, text) in mapOf("folder/book.html" to "<p>正文</p><img src=\"images/pic.png\"/>", "folder/images/pic.png" to "image", "notes.md" to "# 第二本\n\n正文")) {
                zip.putNextEntry(ZipEntry(name)); zip.write(text.toByteArray()); zip.closeEntry()
            }
        }
        val books = BookArchiveImport(root).prepare(source.name, source)
        assertEquals(2, books.size); assertTrue(books.all { it["error"] == null })
        assertTrue(contents(books.first()).contains("image-0.png"))
    }
    @Test fun kindleAliasesUseTheSameUnmodifiedConverter() {
        val source = File(root, "source").apply { writeText("kindle") }
        val importer = BookArchiveImport(root) { _, output -> File(output, "content.opf").writeText("<package/>"); 0 }
        for (ext in listOf("mobi", "azw", "azw3", "prc")) assertEquals("book.epub", importer.prepare("book.$ext", source).single()["name"])
    }
    @Test fun xmlDocumentTypeIsRejectedBeforeEntityExpansion() {
        val failure = assertThrows(Exception::class.java) {
            convert("实体.fb2", """<!DOCTYPE FictionBook [<!ENTITY content "not body text">]><FictionBook><body><section><p>&content;</p></section></body></FictionBook>""")
        }
        assertTrue(failure.message!!.contains("DTD"))
    }
}
