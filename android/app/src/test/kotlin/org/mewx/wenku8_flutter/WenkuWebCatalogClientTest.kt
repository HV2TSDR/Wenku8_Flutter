package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

class WenkuWebCatalogClientTest {
    private class Reply(url: URL, val status: Int = 200, val html: String = "书目", val headers: Map<String, List<String>> = emptyMap()) : HttpURLConnection(url) {
        val output = ByteArrayOutputStream()
        override fun connect() {}
        override fun disconnect() {}
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getHeaderFields() = headers
        override fun getHeaderField(name: String) = headers.entries.firstOrNull { it.key.equals(name, true) }?.value?.firstOrNull()
        override fun getContentType() = "text/html; charset=gbk"
        override fun getInputStream() = ByteArrayInputStream(html.toByteArray(charset("GBK")))
        override fun getOutputStream() = output
    }
    @Test fun officialLoginUsesGbkFormAndRetainsSeparateWebJar() {
        lateinit var reply: Reply
        var requests = 0
        val client = WenkuWebCatalogClient(connect = { url ->
            requests++
            Reply(url, headers = mapOf("Set-Cookie" to if (requests == 1) listOf("PHPSESSID=initial-session-123456; Path=/") else listOf("PHPSESSID=web-session-123456; Path=/", "jieqiUserInfo=web-user; Path=/"))).also { reply = it }
        })
        val web = client.login("用户名", "密码")
        assertTrue(web.hasWebLogin)
        assertEquals("/login.php", reply.url.path)
        assertEquals("do=submit", reply.url.query)
        assertEquals("POST", reply.requestMethod)
        assertTrue(reply.output.toString("US-ASCII").contains("username=%D3%C3%BB%A7%C3%FB&password=%C3%DC%C2%EB"))
        assertEquals(2, requests)
        assertEquals("PHPSESSID=initial-session-123456", reply.getRequestProperty("Cookie"))
        assertEquals(web, ApiSessionCookies.fromStored(web.stored(), requireSession = false))
    }
    @Test fun categoryUsesClassNotLegacyApiSortAndDecodesGbk() {
        lateinit var reply: Reply
        val web = ApiSessionCookies.empty().merge(listOf("jieqiUserInfo=web-user; Path=/"))
        val client = WenkuWebCatalogClient(connect = { url -> Reply(url, html = "电击文库").also { reply = it } })
        assertEquals("电击文库", client.page(3, 2, web).html)
        assertEquals("class=3&sort=lastupdate&page=2", reply.url.query)
        assertEquals("jieqiUserInfo=web-user", reply.getRequestProperty("Cookie"))
        assertEquals(web, ApiSessionCookies.fromStored(web.stored(), requireSession = false))
    }
    @Test fun crossOriginRedirectNeverReceivesCredentials() {
        var requests = 0
        val client = WenkuWebCatalogClient(connect = { url ->
            requests++; Reply(url, status = 307, headers = mapOf("Location" to listOf("https://unrelated.invalid/login")))
        })
        assertThrows(WebCatalogFailure::class.java) { client.login("reader", "secret") }
        assertEquals(1, requests)
    }
    @Test fun forbiddenIsNotTreatedAsExpiredAccountOrRetried() {
        var requests = 0
        val client = WenkuWebCatalogClient(connect = { url -> requests++; Reply(url, status = 403) })
        val web = ApiSessionCookies.empty().merge(listOf("jieqiUserInfo=web-user; Path=/"))
        val error = assertThrows(WebCatalogFailure::class.java) { client.page(1, 1, web) }
        assertEquals("WEB_UNAVAILABLE", error.code)
        assertEquals(1, requests)
    }
    @Test fun phpSessionAloneDoesNotPretendWebsiteLoginSucceeded() {
        val client = WenkuWebCatalogClient(connect = { url -> Reply(url, headers = mapOf("Set-Cookie" to listOf("PHPSESSID=not-authenticated; Path=/"))) })
        val error = assertThrows(WebCatalogFailure::class.java) { client.login("reader", "secret") }
        assertEquals("WEB_LOGIN_FAILED", error.code)
    }
    @Test fun missingAccountRequiresLoginButExistingPhpSessionIsSentToTheServer() {
        var requests = 0
        lateinit var response: Reply
        val client = WenkuWebCatalogClient(connect = { url ->
            requests++; Reply(url).also { response = it }
        })
        val error = assertThrows(WebCatalogFailure::class.java) { client.page(1, 1, null) }
        assertEquals("WEB_LOGIN_REQUIRED", error.code)
        val account = ApiSessionCookies.fromStored("api-session-123456")
        assertEquals("书目", client.page(1, 1, account).html)
        assertEquals("PHPSESSID=api-session-123456", response.getRequestProperty("Cookie"))
        assertEquals(1, requests)
    }
}
