package org.mewx.wenku8_flutter

import java.io.File
import java.io.PushbackReader
import java.nio.charset.Charset

/** Text-bearing RTF: group destinations, Unicode fallbacks and ANSI escapes. */
internal object BookRtfImport {
    private data class State(var ignored: Boolean = false, var unicodeFallback: Int = 1)
    fun read(source: File, writer: BookEpubWriter) {
        source.inputStream().bufferedReader(Charsets.ISO_8859_1).use { raw ->
            raw.mark(4096); val header = CharArray(2048); val count = raw.read(header); raw.reset()
            val prefix = String(header, 0, maxOf(0, count))
            require(prefix.startsWith("{\\rtf")) { "RTF 文件头无效" }
            val cp = Regex("\\\\ansicpg(\\d+)").find(prefix)?.groupValues?.get(1) ?: "1252"
            val charset = when (cp) { "65001" -> Charsets.UTF_8; "936" -> Charset.forName("GBK"); "950" -> Charset.forName("Big5"); "932" -> Charset.forName("Shift_JIS"); else -> Charset.forName("windows-$cp") }
            val reader = PushbackReader(raw, 2)
            val stack = java.util.ArrayDeque<State>(); var state = State(); var fallback = 0
            val text = StringBuilder(); val bytes = java.io.ByteArrayOutputStream()
            fun bytes() { if (bytes.size() > 0) { if (!state.ignored) text.append(bytes.toString(charset.name())); bytes.reset() } }
            fun flush() { bytes(); writer.text(text.toString()); text.setLength(0) }
            fun emit(c: Char) { if (fallback > 0) fallback-- else if (!state.ignored) text.append(c); if (text.length >= 4000) flush() }
            while (true) {
                val next = reader.read(); if (next < 0) break
                when (val c = next.toChar()) {
                    '{' -> { bytes(); require(stack.size < 512) { "RTF 分组层级过深" }; stack.push(state); state = state.copy() }
                    '}' -> { bytes(); require(stack.isNotEmpty()) { "RTF 分组损坏" }; state = stack.pop() }
                    '\\' -> {
                        val escaped = reader.read(); if (escaped < 0) error("RTF 转义不完整")
                        val symbol = escaped.toChar()
                        if (symbol == '\'') {
                            val hex = "${reader.read().toChar()}${reader.read().toChar()}"
                            val value = hex.toIntOrNull(16) ?: error("RTF 字符转义无效")
                            if (fallback > 0) fallback-- else if (!state.ignored) bytes.write(value)
                            continue
                        }
                        bytes()
                        if (!symbol.isLetter()) {
                            when (symbol) { '*' -> state.ignored = true; '\\', '{', '}' -> emit(symbol); '~' -> emit(' '); '_' -> emit('-') }
                            continue
                        }
                        val word = StringBuilder().append(symbol)
                        var code = reader.read()
                        while (code >= 0 && code.toChar().isLetter()) { require(word.length < 64) { "RTF 控制词无效" }; word.append(code.toChar()); code = reader.read() }
                        val number = StringBuilder()
                        if (code == '-'.code || code >= 0 && code.toChar().isDigit()) {
                            number.append(code.toChar()); code = reader.read()
                            while (code >= 0 && code.toChar().isDigit()) { require(number.length < 12) { "RTF 参数无效" }; number.append(code.toChar()); code = reader.read() }
                        }
                        if (code >= 0 && code != ' '.code) reader.unread(code)
                        val value = number.toString().toIntOrNull() ?: 0
                        when (word.toString()) {
                            "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "header", "footer", "fldinst" -> state.ignored = true
                            "uc" -> state.unicodeFallback = value.coerceIn(0, 16)
                            "u" -> { if (!state.ignored) text.append(value.toChar()); fallback = state.unicodeFallback }
                            "par", "line", "page" -> if (!state.ignored) flush()
                            "tab" -> emit(' ')
                            "emdash" -> emit('—')
                            "endash" -> emit('–')
                            "lquote", "rquote" -> emit('\'')
                            "ldblquote", "rdblquote" -> emit('"')
                            "bin" -> { require(value >= 0) { "RTF 二进制长度无效" }; repeat(value) { require(reader.read() >= 0) { "RTF 二进制内容不完整" } } }
                        }
                    }
                    '\r', '\n' -> Unit
                    else -> if (c.code >= 128) { if (fallback > 0) fallback-- else if (!state.ignored) bytes.write(c.code) } else { bytes(); emit(c) }
                }
            }
            require(stack.isEmpty()) { "RTF 文件不完整" }; flush()
        }
    }
}
