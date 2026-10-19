package org.mewx.wenku8_flutter

import java.io.File
import java.io.InputStreamReader
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** Bounded buffers, including charset fallback. No whole-book Java String or
 * platform-channel payload is needed for large TXT imports. */
internal object BookTextDecoder {
    const val MAX_TEXT = 128L * 1024 * 1024
    fun normalize(source: File, target: File, requested: String = "auto") {
        require(source.length() in 1..MAX_TEXT) { "单本 TXT 需要在 128 MiB 以内" }
        require(requested in setOf("auto", "UTF-8", "GB18030", "UTF-16LE", "UTF-16BE")) { "不支持的文本编码" }
        val prefix = source.inputStream().use { input -> ByteArray(3).also { input.read(it) } }
        val charset = when {
            requested != "auto" -> Charset.forName(requested)
            prefix[0] == 0xff.toByte() && prefix[1] == 0xfe.toByte() -> Charsets.UTF_16LE
            prefix[0] == 0xfe.toByte() && prefix[1] == 0xff.toByte() -> Charsets.UTF_16BE
            else -> Charsets.UTF_8
        }
        fun decode(encoding: Charset) {
            val decoder = encoding.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            InputStreamReader(source.inputStream(), decoder).use { reader ->
                target.bufferedWriter(Charsets.UTF_8, 64 * 1024).use { writer ->
                    val buffer = CharArray(32 * 1024)
                    var first = true
                    while (true) {
                        val count = reader.read(buffer)
                        if (count < 0) break
                        val start = if (first && count > 0 && buffer[0] == '\uFEFF') 1 else 0
                        if (count > 0) first = false
                        writer.write(buffer, start, count - start)
                    }
                }
            }
        }
        try {
            try { decode(charset) }
            catch (failure: CharacterCodingException) {
                if (requested != "auto" || charset != Charsets.UTF_8) throw failure
                decode(Charset.forName("GB18030"))
            }
        } catch (failure: Exception) { target.delete(); throw failure }
    }
}
