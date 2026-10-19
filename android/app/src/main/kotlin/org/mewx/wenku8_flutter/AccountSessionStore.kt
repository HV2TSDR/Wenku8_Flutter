package org.mewx.wenku8_flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound session only: no password, export, log or Android backup. */
internal class AccountSessionStore(context: Context, scope: String? = null) {
    private val web = scope == "web"
    private val preferences = context.getSharedPreferences(if (web) "wenku_web_session" else "wenku_account_session", Context.MODE_PRIVATE)
    private val alias = if (web) "wenku8.web.session.v1" else "wenku8.account.session.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun read(): String? = try {
        preferences.getString("sealed", null)?.let { sealed ->
            val parts = sealed.split(":")
            if (parts.size != 2) throw IllegalArgumentException()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)).toString(Charsets.UTF_8)
                .also { ApiSessionCookies.fromStored(it, requireSession = !web) }
        }
    } catch (_: Exception) {
        preferences.edit().clear().commit()
        null
    }
    fun write(cookie: String?) {
        cookie?.let { ApiSessionCookies.fromStored(it, requireSession = !web) }
        val editor = preferences.edit()
        if (cookie == null) editor.clear() else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
            val body = Base64.encodeToString(cipher.doFinal(cookie.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
            editor.putString("sealed", "$iv:$body")
        }
        check(editor.commit()) { "Session storage failed" }
    }
}
