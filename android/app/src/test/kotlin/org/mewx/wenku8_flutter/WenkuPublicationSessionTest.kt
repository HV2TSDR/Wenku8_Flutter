package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.HttpURLConnection
import java.net.URL

class WenkuPublicationSessionTest {
    private class Reply(url: URL, val html: String, val status: Int = 200) : HttpURLConnection(url) {
        override fun connect() {}
        override fun disconnect() {}
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getContentType() = "text/html; charset=gbk"
        override fun getHeaderFields(): Map<String, List<String>> = emptyMap()
        override fun getInputStream() = ByteArrayInputStream(html.toByteArray(charset("GBK")))
    }
    private val account = ApiSessionCookies.fromStored("account-session-123456")
    @Test fun workingRichListIsNotDiscardedForTheRetiredIdListOrDeniedWebsite() {
        var webCalls = 0
        val actions = mutableListOf<String>()
        val session = WenkuPublicationSession(WenkuWebCatalogClient(connect = { url ->
            webCalls++; Reply(url, "", 403)
        }))
        val reply = session.read(1, 1, account, null) { action, jar ->
            actions.add(action)
            WenkuPublicationSession.ApiReply(if (action.startsWith("action=novellist&"))
                "<result><page num='9'/><item aid='1305'><data name='Title' value='作品'/></item></result>" else "4", jar)
        }
        assertTrue(reply.body.contains("1305"))
        assertEquals(listOf("action=novellist&sort=1&page=1&t=0"), actions)
        assertEquals(0, webCalls)
    }
    @Test fun apiCategoriesUseTheRestoredAccountWithoutWebsiteLogin() {
        val session = WenkuPublicationSession(WenkuWebCatalogClient(connect = { error("No website login required") }))
        val reply = session.read(2, 3, account, null) { action, jar ->
            assertSame(account, jar)
            assertEquals("action=novellist&sort=2&page=3&t=0", action)
            WenkuPublicationSession.ApiReply("<result><page num='8'/><item aid='1305'/></result>", jar)
        }
        assertTrue(reply.body.contains("1305"))
        assertEquals(account, reply.apiCookies)
    }
    @Test fun retiredApiActionUsesExistingAccountJarNotAnotherPassword() {
        var calls = 0
        val replies = mutableListOf<Reply>()
        val session = WenkuPublicationSession(WenkuWebCatalogClient(connect = { url ->
            Reply(url, "<div id='content'><a href='/book/1305.htm'>书籍</a></div>").also { replies.add(it) }
        }))
        for (page in 1..2) {
            val reply = session.read(1, page, account, null) { _, jar -> calls++; WenkuPublicationSession.ApiReply("4", jar) }
            assertTrue(reply.body.contains("1305"))
        }
        assertEquals(1, calls)
        assertTrue(replies.all { it.getRequestProperty("Cookie") == account.header() })
        session.reset()
        session.read(1, 1, account, null) { _, jar -> calls++; WenkuPublicationSession.ApiReply("4", jar) }
        assertEquals(2, calls)
    }
    @Test fun unavailableWebsiteDoesNotClearOrRetryAccount() {
        var webCalls = 0
        val session = WenkuPublicationSession(WenkuWebCatalogClient(connect = { url -> webCalls++; Reply(url, "", 403) }))
        val error = assertThrows(WebCatalogFailure::class.java) {
            session.read(1, 1, account, null) { _, jar -> WenkuPublicationSession.ApiReply("4", jar) }
        }
        assertEquals("WEB_UNAVAILABLE", error.code)
        assertEquals(1, webCalls)
        assertTrue(account.hasSession)
    }
    @Test fun loggedOutAccountNeverUsesAStaleWebsiteJar() {
        val session = WenkuPublicationSession(WenkuWebCatalogClient(connect = { error("No request while logged out") }))
        assertThrows(WebCatalogFailure::class.java) {
            session.read(1, 1, null, account) { _, _ -> error("No request while logged out") }
        }
    }
    @Test fun refreshedAccountRetriesApiInsteadOfPermanentlyCachingARefusal() {
        var calls = 0
        val session = WenkuPublicationSession(WenkuWebCatalogClient(connect = { url -> Reply(url, "<div id='content'>暂无书籍</div>") }))
        session.read(1, 1, account, null) { _, jar -> calls++; WenkuPublicationSession.ApiReply("4", jar) }
        val refreshed = ApiSessionCookies.fromStored("refreshed-session-234567")
        val reply = session.read(1, 1, refreshed, null) { _, jar -> calls++; WenkuPublicationSession.ApiReply("\uFEFF<result/>", jar) }
        assertEquals(2, calls)
        assertEquals("<result/>", reply.body)
    }
}
