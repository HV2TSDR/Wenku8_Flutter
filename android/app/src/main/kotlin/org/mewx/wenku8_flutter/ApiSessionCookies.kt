package org.mewx.wenku8_flutter

import java.net.HttpCookie

/** A relay-scoped account jar. Guest requests never receive or mutate it. */
internal class ApiSessionCookies private constructor(private val values: Map<String, String>) {
    val hasSession: Boolean get() = sessionId.matches(values["PHPSESSID"] ?: "")
    val hasWebLogin: Boolean get() = !values["jieqiUserInfo"].isNullOrEmpty()
    fun header(): String = values.entries.joinToString("; ") { "${it.key}=${it.value}" }
    fun stored(): String = prefix + header()
    // Only the site's CMS session is transferable from its API relay. Relay
    // infrastructure cookies remain scoped to the API, not another host.
    fun websiteSession(): ApiSessionCookies = checked(values.filterKeys { it == "PHPSESSID" || it.startsWith("jieqi") })

    fun merge(headers: List<String>): ApiSessionCookies {
        val next = LinkedHashMap(values)
        for (header in headers) {
            // Workers can combine Set-Cookie fields. Do not split the comma in
            // an Expires date, or discard every cookie except PHPSESSID.
            for (field in header.split(combined)) {
                for (cookie in HttpCookie.parse(field)) {
                    validate(cookie.name, cookie.value)
                    if (cookie.hasExpired() || cookie.value.isEmpty()) next.remove(cookie.name)
                    else next[cookie.name] = cookie.value
                }
            }
        }
        return checked(next)
    }

    override fun equals(other: Any?): Boolean = other is ApiSessionCookies && values == other.values
    override fun hashCode(): Int = values.hashCode()

    companion object {
        private const val prefix = "cookies-v2:"
        private val sessionId = Regex("[A-Za-z0-9,-]{8,256}")
        private val cookieName = Regex("[!#$%&'*+.^_`|~A-Za-z0-9-]+")
        private val combined = Regex(",\\s*(?=[!#$%&'*+.^_`|~A-Za-z0-9-]+=)")
        fun empty() = ApiSessionCookies(emptyMap())
        fun fromStored(value: String, requireSession: Boolean = true): ApiSessionCookies {
            // Existing encrypted v1 sessions stay usable after upgrading.
            if (sessionId.matches(value)) return checked(mapOf("PHPSESSID" to value))
            require(value.startsWith(prefix))
            val pairs = linkedMapOf<String, String>()
            for (part in value.removePrefix(prefix).split("; ")) {
                val pair = part.split('=', limit = 2)
                require(pair.size == 2)
                validate(pair[0], pair[1])
                pairs[pair[0]] = pair[1]
            }
            return checked(pairs).also { require(!requireSession || it.hasSession) }
        }
        private fun checked(values: Map<String, String>): ApiSessionCookies {
            require(values.size <= 32)
            for ((name, value) in values) validate(name, value)
            return ApiSessionCookies(values.toMap()).also { require(it.header().length <= 16384) }
        }
        private fun validate(name: String, value: String) {
            require(cookieName.matches(name))
            require(value.length <= 8192 && value.all { it.code in 0x21..0x7e && it != ';' })
        }
    }
}
