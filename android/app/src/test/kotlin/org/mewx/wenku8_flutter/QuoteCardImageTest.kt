package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.Test

class QuoteCardImageTest {
    private fun header(width: Int = 1080, height: Int = 1800): ByteArray {
        val bytes = ByteArray(33)
        byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a).copyInto(bytes)
        "IHDR".toByteArray().copyInto(bytes, 12)
        for ((offset, value) in listOf(16 to width, 20 to height)) {
            for (index in 0..3) bytes[offset + index] = (value ushr (24 - index * 8)).toByte()
        }
        return bytes
    }
    @Test fun onlyBoundedPngImagesEnterTheSharePath() {
        assertTrue(QuoteCardImage.valid(header()))
        assertFalse(QuoteCardImage.valid(null))
        assertFalse(QuoteCardImage.valid(ByteArray(32)))
        assertFalse(QuoteCardImage.valid(header(0)))
        assertFalse(QuoteCardImage.valid(header(-1)))
        assertFalse(QuoteCardImage.valid(header(4097)))
        assertFalse(QuoteCardImage.valid(header(height = 8193)))
        assertFalse(QuoteCardImage.valid(header(4096, 4096)))
        assertFalse(QuoteCardImage.valid(header().apply { this[0] = 0 }))
        assertFalse(QuoteCardImage.valid(header().apply { this[12] = 0 }))
        assertFalse(QuoteCardImage.valid(header().copyOf(12 * 1024 * 1024 + 1)))
    }
    @Test fun chosenFileNamesCannotBecomePaths() {
        assertEquals("文库摘录.png", QuoteCardImage.fileName(null))
        assertEquals("文库摘录.png", QuoteCardImage.fileName(""))
        assertEquals("摘录.png", QuoteCardImage.fileName("摘录.png"))
        assertFalse(QuoteCardImage.fileName("../恶意/文件\n").contains('/'))
        assertTrue(QuoteCardImage.fileName("a".repeat(200)).length <= 104)
    }
}
