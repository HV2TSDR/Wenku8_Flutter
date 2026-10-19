package org.mewx.wenku8_flutter

/** One signed-in identity, with API-first classification. A retired list action
 * is not an expired account; its official-site fallback reuses the same jar. */
internal class WenkuPublicationSession(private val website: WenkuWebCatalogClient) {
    data class ApiReply(val body: String, val cookies: ApiSessionCookies)
    data class Reply(val body: String, val apiCookies: ApiSessionCookies? = null,
        val webCookies: ApiSessionCookies? = null)
    private var websiteOnly = false
    private var observedAccount: ApiSessionCookies? = null
    fun reset() { websiteOnly = false; observedAccount = null }
    fun read(library: Int, page: Int, account: ApiSessionCookies?, web: ApiSessionCookies?,
        request: (String, ApiSessionCookies) -> ApiReply): Reply {
        require(library in 1..10000 && page in 1..100000)
        if (account?.hasSession != true) throw WebCatalogFailure("WEB_LOGIN_REQUIRED", "请先登录文库账号")
        if (observedAccount != account) { websiteOnly = false; observedAccount = account }
        if (!websiteOnly) {
            val result = request("action=novellist&sort=$library&page=$page&t=0", account)
            val body = result.body.trim().removePrefix("\uFEFF").trimStart()
            if (Regex("^(?:<\\?xml[^>]*>\\s*)?<result(?:\\s|/|>)").containsMatchIn(body)) {
                return Reply(body, apiCookies = result.cookies)
            }
            if (body != "4") throw WebCatalogFailure("WEB_RESPONSE", "出版分类返回格式有误，请稍后重试")
            websiteOnly = true
        }
        val result = website.page(library, page, web ?: account.websiteSession())
        return Reply(result.html, webCookies = result.cookies.takeIf { web != null || it.hasWebLogin })
    }
}
