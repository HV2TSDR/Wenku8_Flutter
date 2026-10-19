package org.mewx.wenku8_flutter

import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.nio.charset.Charset

class BookTextDecoderTest {
    @Test fun largeUtf8IsNormalizedWithBoundedBuffers() {
        val root = kotlin.io.path.createTempDirectory("wenku-large-txt-").toFile()
        try {
            val source = File(root, "large.txt")
            val block = ("正文的测试行😀。\n".repeat(2000)).toByteArray()
            source.outputStream().use { output -> while (source.length() <= 65L * 1024 * 1024) output.write(block) }
            val target = File(root, "normalized.txt")
            BookTextDecoder.normalize(source, target)
            assertTrue(target.length() > 65L * 1024 * 1024)
            target.bufferedReader().use { assertEquals("正文的测试行😀。", it.readLine()) }
            assertEquals(source.length(), target.length())
        } finally { root.deleteRecursively() }
    }
    @Test fun gb18030AndBomUtf16AreStrictAndDoNotLeakPartialOutput() {
        val root = kotlin.io.path.createTempDirectory("wenku-txt-encoding-").toFile()
        try {
            val source = File(root, "source")
            val target = File(root, "decoded")
            val text = "第一卷\n第一章\n中文内容。😀"
            for (encoding in listOf("GB18030", "UTF-16LE", "UTF-16BE")) {
                val bytes = text.toByteArray(Charset.forName(encoding))
                source.writeBytes(when (encoding) { "UTF-16LE" -> byteArrayOf(-1, -2) + bytes; "UTF-16BE" -> byteArrayOf(-2, -1) + bytes; else -> bytes })
                BookTextDecoder.normalize(source, target)
                assertEquals(text, target.readText())
            }
            source.writeBytes(byteArrayOf(0xff.toByte()))
            try { BookTextDecoder.normalize(source, target, "UTF-8"); fail("malformed text accepted") } catch (_: java.nio.charset.CharacterCodingException) { }
            assertFalse(target.exists())
        } finally { root.deleteRecursively() }
    }
}
