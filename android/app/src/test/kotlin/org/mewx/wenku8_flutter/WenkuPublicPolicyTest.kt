package org.mewx.wenku8_flutter

import java.net.URL
import org.junit.Assert.*
import org.junit.Test

class WenkuPublicPolicyTest {
    @Test fun onlyCoverReadsMapToPublicImages() {
        assertEquals("https://img.wenku8.com/image/1/1305/1305s.jpg", WenkuPublicPolicy.cover("action=book&do=cover&aid=1305")?.toString())
        for (action in listOf("action=login&username=a&password=b", "action=userinfo", "action=bookcase&t=0", "action=book&do=meta&aid=1305&t=0", "action=book&do=cover&aid=1&password=x", "action=book&do=text&aid=1&cid=2")) assertNull(action, WenkuPublicPolicy.cover(action))
    }
    @Test fun onlyKnownImagePaths() {
        assertTrue(WenkuPublicPolicy.image(URL("https://img.wenku8.com/image/1/1305/1305s.jpg")))
        assertTrue(WenkuPublicPolicy.image(URL("https://pic.777743.xyz/1/1305/41759/50471.jpg")))
        for (raw in listOf("https://evil.test/1/a.jpg", "https://www.wenku8.com/login.php", "https://img.wenku8.com/image/1/a.jpg?token=x", "https://u:p@img.wenku8.com/image/1/a.jpg", "http://img.wenku8.com/image/1/a.jpg")) assertFalse(raw, WenkuPublicPolicy.image(URL(raw)))
    }
}
