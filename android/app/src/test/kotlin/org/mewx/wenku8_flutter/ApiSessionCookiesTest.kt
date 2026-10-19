package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.Test

class ApiSessionCookiesTest {
    @Test fun oldEncryptedPayloadRemainsUsable() {
        val jar = ApiSessionCookies.fromStored("old-session-123456")
        assertTrue(jar.hasSession)
        assertEquals("PHPSESSID=old-session-123456", jar.header())
        assertEquals(jar, ApiSessionCookies.fromStored(jar.stored()))
    }
    @Test fun loginRetainsAllAccountCookiesWithoutAttributes() {
        val jar = ApiSessionCookies.empty().merge(listOf(
            "PHPSESSID=api-session-123456; Path=/; HttpOnly; Secure",
            "jieqiUserInfo=%7B%22uid%22%3A71%7D; Path=/; SameSite=Lax"
        ))
        assertTrue(jar.hasSession)
        assertEquals("PHPSESSID=api-session-123456; jieqiUserInfo=%7B%22uid%22%3A71%7D", jar.header())
        assertEquals(jar, ApiSessionCookies.fromStored(jar.stored()))
    }
    @Test fun combinedHeadersKeepExpiresCommaAndOpaqueValues() {
        val jar = ApiSessionCookies.empty().merge(listOf(
            "PHPSESSID=api-session-123456; Path=/, jieqiUserInfo=abc==; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/"
        ))
        assertTrue(jar.hasSession)
        assertTrue(jar.header().contains("jieqiUserInfo=abc=="))
        assertFalse(jar.header().contains("Expires"))
    }
    @Test fun rotationPreservesOtherCookiesAndExpiresOnlyItsTarget() {
        val first = ApiSessionCookies.empty().merge(listOf(
            "PHPSESSID=api-session-123456; Path=/", "jieqiUserInfo=book-reader; Path=/"
        ))
        val rotated = first.merge(listOf("PHPSESSID=rotated-session-234567; Path=/"))
        assertTrue(rotated.header().contains("jieqiUserInfo=book-reader"))
        val cleared = rotated.merge(listOf("jieqiUserInfo=gone; Max-Age=0; Path=/"))
        assertEquals("PHPSESSID=rotated-session-234567", cleared.header())
        assertTrue(first.header().contains("api-session-123456"))
    }
    @Test fun expiredSessionIsNotConsideredAuthenticated() {
        val jar = ApiSessionCookies.fromStored("old-session-123456")
            .merge(listOf("PHPSESSID=gone; Max-Age=0; Path=/"))
        assertFalse(jar.hasSession)
    }
    @Test fun malformedPersistedHeaderCannotInjectRequestHeaders() {
        for (value in listOf("cookies-v2:PHPSESSID=abcd123456\r\nCookie: bad=1", "cookies-v2:PHPSESSID=short", "cookies-v2:bad name=value")) {
            assertThrows(IllegalArgumentException::class.java) { ApiSessionCookies.fromStored(value) }
        }
    }
    @Test fun websiteReuseTransfersCmsSessionButNotRelayInfrastructureCookies() {
        val account = ApiSessionCookies.fromStored("account-session-123456").merge(listOf(
            "jieqiUserInfo=reader; Path=/", "relayRouting=private-route; Path=/"
        ))
        assertEquals("PHPSESSID=account-session-123456; jieqiUserInfo=reader", account.websiteSession().header())
        assertTrue(account.header().contains("relayRouting"))
    }
}
