package org.mewx.wenku8_flutter

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.zip.GZIPInputStream

internal class WebCatalogFailure(val code: String, val publicMessage: String) : Exception(publicMessage)

/** Official website session, deliberately separate from the API relay session. */
internal class WenkuWebCatalogClient(
    private val origin: URL = URL("https://www.wenku8.net/"),
    private val connect: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
) {
    data class Page(val html: String, val cookies: ApiSessionCookies)

    fun login(username: String, password: String, account: ApiSessionCookies = ApiSessionCookies.empty()): ApiSessionCookies {
        require(username.isNotBlank() && username.length <= 254 && password.length in 1..30)
        val encoder = charset("GBK").newEncoder()
        if (!encoder.canEncode(username) || !encoder.canEncode(password))
            throw WebCatalogFailure("WEB_LOGIN_FAILED", "官网账号使用 GBK 编码，无法提交这些字符")
        val body = "username=${URLEncoder.encode(username, "GBK")}&password=${URLEncoder.encode(password, "GBK")}&action=login&usecookie=315360000"
        // Seed the site's PHP session before submitting the same transient
        // account login. No second password form or stored password is needed.
        val initial = request(URL(origin, "login.php"), account.websiteSession())
        val reply = request(URL(origin, "login.php?do=submit"), initial.cookies, body)
        if (!reply.cookies.hasWebLogin) {
            val message = if (reply.html.contains("验证码")) "官网要求额外验证，暂时无法连接分类"
                else "官网未接受本次账号登录，当前文库账号仍保持登录"
            throw WebCatalogFailure("WEB_LOGIN_FAILED", message)
        }
        return reply.cookies
    }

    fun page(library: Int, page: Int, cookies: ApiSessionCookies?): Page {
        require(library in 1..10000 && page in 1..100000)
        if (cookies == null) throw WebCatalogFailure("WEB_LOGIN_REQUIRED", "请先登录文库账号")
        return request(URL(origin, "modules/article/articlelist.php?class=$library&sort=lastupdate&page=$page"), cookies)
    }

    private fun request(start: URL, initial: ApiSessionCookies, form: String? = null): Page {
        var url = start
        var cookies = initial
        var body = form
        for (hop in 0..3) {
            val connection = connect(url).apply {
                connectTimeout = 8000; readTimeout = 15000
                instanceFollowRedirects = false
                setRequestProperty("Accept-Encoding", "gzip")
                setRequestProperty("Accept", "text/html,application/xhtml+xml")
                if (cookies.header().isNotEmpty()) setRequestProperty("Cookie", cookies.header())
                if (body != null) {
                    requestMethod = "POST"; doOutput = true
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=GBK")
                    setRequestProperty("Referer", URL(origin, "login.php").toString())
                }
            }
            try {
                body?.let { data -> connection.outputStream.use { it.write(data.toByteArray(Charsets.US_ASCII)) } }
                val status = connection.responseCode
                val headers = connection.headerFields.entries.filter { it.key?.equals("Set-Cookie", true) == true }.flatMap { it.value }
                cookies = cookies.merge(headers)
                if (status in setOf(301, 302, 303, 307, 308)) {
                    val location = connection.getHeaderField("Location") ?: throw WebCatalogFailure("WEB_RESPONSE", "分类跳转地址无效")
                    val next = URL(url, location)
                    if (hop == 3 || next.protocol != origin.protocol || next.host != origin.host || next.port != origin.port || next.userInfo != null)
                        throw WebCatalogFailure("WEB_RESPONSE", "分类连接地址发生变化，请稍后重试")
                    url = next
                    if (status !in setOf(307, 308)) body = null
                    continue
                }
                if (status == 403 || status == 429) throw WebCatalogFailure("WEB_UNAVAILABLE", "官网暂时拒绝分类请求，请稍后重试；当前账号仍保持登录")
                if (status !in 200..299) throw WebCatalogFailure("WEB_UNAVAILABLE", "官网分类暂时不可用，请稍后重试")
                val stream = if (connection.contentEncoding?.contains("gzip", true) == true) GZIPInputStream(connection.inputStream) else connection.inputStream
                val bytes = stream.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (output.size() + read > 2 * 1024 * 1024) throw WebCatalogFailure("WEB_RESPONSE", "分类页面超过大小限制")
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray()
                }
                val utf8 = connection.contentType?.contains("utf-8", true) == true ||
                    bytes.take(2048).toByteArray().toString(Charsets.ISO_8859_1).contains(Regex("charset\\s*=\\s*[\"']?utf-8", RegexOption.IGNORE_CASE))
                return Page(bytes.toString(if (utf8) Charsets.UTF_8 else charset("GB18030")), cookies)
            } finally { connection.disconnect() }
        }
        throw WebCatalogFailure("WEB_RESPONSE", "分类跳转次数过多")
    }
}
