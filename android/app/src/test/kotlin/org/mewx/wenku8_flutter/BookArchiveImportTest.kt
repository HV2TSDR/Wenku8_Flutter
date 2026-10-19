package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

class BookArchiveImportTest {
    private val root = Files.createTempDirectory("wenku-import-test-").toFile()
    @After fun cleanup() { root.deleteRecursively() }
    private fun zip(vararg entries: Pair<String, String>): File = File(root, "input.zip").also { file ->
        ZipOutputStream(file.outputStream()).use { output ->
            for ((name, value) in entries) {
                output.putNextEntry(ZipEntry(name)); output.write(value.toByteArray()); output.closeEntry()
            }
        }
    }
    @Test fun archiveFlattensFoldersAndKeepsPartialFailures() {
        val source = zip("系列/作品 第1卷.txt" to "正文一", "系列/作品 第2卷.epub" to "epub",
            "损坏.mobi" to "invalid", "__MACOSX/ignored.txt" to "skip", "nested.zip" to "skip", "封面.jpg" to "skip")
        val result = BookArchiveImport(root) { _, _ -> 2 }.prepare("合集.ZIP", source)
        assertEquals(listOf("作品 第1卷.txt", "作品 第2卷.epub", "损坏.mobi"), result.map { it["name"] })
        assertEquals(2, result.count { it["path"] != null })
        assertTrue(result.last()["error"]!!.contains("损坏"))
        for (item in result.filter { it["path"] != null }) assertEquals(root.canonicalFile, File(item["path"]!!).canonicalFile.parentFile)
        assertTrue(source.isFile)
    }
    @Test fun unsafeArchiveDoesNotLeavePreparedFiles() {
        val source = zip("good.txt" to "book", "../outside.txt" to "unsafe")
        assertThrows(IllegalArgumentException::class.java) { BookArchiveImport(root).prepare("x.zip", source) }
        assertEquals(listOf("input.zip"), root.listFiles()!!.map { it.name })
    }
    @Test fun archiveLimitAndUnsupportedFilesHaveSpecificFailures() {
        val tooMany = (0..200).map { "$it.txt" to "text" }.toTypedArray()
        val source = zip(*tooMany)
        val failure = assertThrows(IllegalArgumentException::class.java) { BookArchiveImport(root).prepare("x.zip", source) }
        assertTrue(failure.message!!.contains("200"))
        assertThrows(IllegalArgumentException::class.java) { BookArchiveImport(root).prepare("x.zip", zip("image.jpg" to "image")) }
    }
    @Test fun legacyChineseZipFilenamesRemainReadable() {
        val source = File(root, "legacy.zip")
        ZipOutputStream(source.outputStream(), charset("GBK")).use { zip ->
            zip.putNextEntry(ZipEntry("合集/第一卷.txt")); zip.write("正文".toByteArray()); zip.closeEntry()
        }
        assertEquals("第一卷.txt", BookArchiveImport(root).prepare("legacy.zip", source).single()["name"])
    }
    private fun fakeExport(input: String, output: String): Int {
        assertTrue(File(input).isFile)
        File(output, "content.opf").writeText("<package><metadata/><manifest/><spine/></package>")
        File(output, "part00000.html").writeText("<html><body><p>小说正文</p></body></html>")
        File(output, "resource00001.png").writeBytes(byteArrayOf(1, 2, 3))
        return 0
    }
    @Test fun mobiConversionIsDeterministicAndOriginalIsUntouched() {
        val source = File(root, "source.mobi").apply { writeText("original") }
        val importer = BookArchiveImport(root, ::fakeExport)
        val first = importer.prepare("系列 第1卷.mobi", source).single()
        val second = importer.prepare("系列 第1卷.mobi", source).single()
        assertEquals("系列 第1卷.epub", first["name"])
        assertArrayEquals(File(first["path"]!!).readBytes(), File(second["path"]!!).readBytes())
        assertEquals("original", source.readText())
        ZipFile(first["path"]!!).use { archive ->
            assertEquals("mimetype", archive.entries().nextElement().name)
            assertEquals(ZipEntry.STORED, archive.getEntry("mimetype").method)
            assertNotNull(archive.getEntry("OEBPS/content.opf"))
            assertNotNull(archive.getEntry("OEBPS/resource00001.png"))
            assertTrue(archive.getInputStream(archive.getEntry("META-INF/container.xml")).reader().readText().contains("OEBPS/content.opf"))
        }
        assertFalse(root.listFiles()!!.any { it.isDirectory })
    }
    @Test fun protectedAndInvalidMobiLeaveNoConvertedFile() {
        val source = File(root, "source.mobi").apply { writeText("protected") }
        val importer = BookArchiveImport(root) { _, _ -> 1 }
        val failure = assertThrows(IllegalArgumentException::class.java) { importer.prepare("x.mobi", source) }
        assertTrue(failure.message!!.contains("DRM"))
        assertEquals(listOf("source.mobi"), root.listFiles()!!.map { it.name })
    }
    @Test fun realMobiFixturesConvertThroughTheProductionPackager() {
        val executable = System.getenv("WENKU_MOBI_HOST")
        val fixtures = System.getenv("WENKU_MOBI_SAMPLES")
        assumeTrue("Set host exporter and upstream fixtures to run the native corpus", executable != null && fixtures != null)
        val destination = System.getenv("WENKU_MOBI_EPUBS")?.let { File(it).apply { mkdirs() } }
        val importer = BookArchiveImport(root) { input, output ->
            ProcessBuilder(executable!!, input, output).redirectErrorStream(true).start().let { process ->
                process.inputStream.readBytes(); process.waitFor()
            }
        }
        for (name in listOf("sample-cp1252", "sample-unicode-uncompressed", "sample-unicode-huffdic", "sample-ncx", "sample-textread", "sample-multimedia", "sample-obfuscated-fonts")) {
            val source = File(fixtures!!, "$name.mobi")
            val prepared = importer.prepare(source.name, source).single()
            val epub = File(prepared["path"]!!)
            val repeated = importer.prepare(source.name, source).single()
            assertArrayEquals("Reimport must deduplicate: $name", epub.readBytes(), File(repeated["path"]!!).readBytes())
            ZipFile(epub).use { archive -> assertNotNull("Missing OPF: $name", archive.getEntry("OEBPS/content.opf")) }
            destination?.let { epub.copyTo(File(it, "$name.epub"), overwrite = true) }
        }
    }
}
