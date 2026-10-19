package org.mewx.wenku8_flutter

import android.content.Context
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Semaphore
import java.util.zip.GZIPInputStream

/** Image-only backup; all catalogue/account requests retain the existing Cloudflare relay. */
internal object WenkuPublicPolicy {
    fun cover(raw: String): URL? {
        val aid = Regex("action=book&do=cover&aid=([1-9]\\d{0,7})(?:&t=0)?").matchEntire(raw)?.groupValues?.get(1)?.toIntOrNull() ?: return null
        return URL("https://img.wenku8.com/image/${aid / 1000}/$aid/${aid}s.jpg")
    }

    fun image(url: URL): Boolean = try {
        val uri = url.toURI()
        uri.scheme == "https" && uri.userInfo == null && uri.port == -1 && uri.rawQuery == null && uri.rawFragment == null &&
            uri.host in setOf("img.wenku8.com", "pic.wenku8.com", "pic.wenku8.cn", "pic.wenku8.net", "pic.777743.xyz") &&
            uri.path.matches(Regex("/(?:image|pictures|\\d+)/[a-zA-Z0-9_/-]+\\.(?:jpe?g|png|gif|webp)", RegexOption.IGNORE_CASE))
    } catch (_: Exception) { false }
}

internal class WenkuPublicGateway(context: Context) {
    private val preferences = context.getSharedPreferences("wenku8-public-routing", Context.MODE_PRIVATE)
    private val slots = Semaphore(2)
    @Volatile var updatePriority = false
    @Volatile private var bypassUntil = preferences.getLong("bypassUntil", 0L)

    fun cover(action: String): ByteArray? = WenkuPublicPolicy.cover(action)?.let { image(it) }

    fun image(source: URL): ByteArray? {
        if (!WenkuPublicPolicy.image(source)) return null
        val path = Base64.encodeToString(source.toString().toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        return attempt("/image/$path")
    }

    private fun attempt(path: String): ByteArray? {
        if (updatePriority || System.currentTimeMillis() < bypassUntil || !slots.tryAcquire()) return null
        var connection: HttpURLConnection? = null
        try {
            if (updatePriority) return null
            connection = (URL("https://app.3952039.xyz$path").openConnection() as HttpURLConnection).apply {
                connectTimeout = 2500
                readTimeout = 4000
                instanceFollowRedirects = false
                setRequestProperty("Accept-Encoding", "gzip")
                setRequestProperty("User-Agent", "Wenku8-Flutter")
            }
            if (connection.responseCode != 200) {
                val seconds = connection.getHeaderField("Retry-After")?.toLongOrNull()?.coerceIn(60L, 86400L) ?: 60L
                bypass(seconds)
                return null
            }
            val stream = if (connection.contentEncoding?.contains("gzip", ignoreCase = true) == true) GZIPInputStream(connection.inputStream) else connection.inputStream
            return stream.use { input ->
                val output = ByteArrayOutputStream()
                val bytes = ByteArray(16384)
                while (true) {
                    val count = input.read(bytes)
                    if (count < 0) break
                    require(output.size() + count <= 8 * 1024 * 1024)
                    output.write(bytes, 0, count)
                }
                require(output.size() > 0)
                output.toByteArray()
            }
        } catch (_: Exception) {
            bypass(60L)
            return null
        } finally {
            connection?.disconnect()
            slots.release()
        }
    }

    private fun bypass(seconds: Long) {
        bypassUntil = System.currentTimeMillis() + seconds * 1000L
        preferences.edit().putLong("bypassUntil", bypassUntil).apply()
    }
}
