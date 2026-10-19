package org.mewx.wenku8_flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound vault, separate from the Wenku account cookie alias. */
class CustomSpeechConfigPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val alias = "wenku8.custom-speech.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return (store.getKey(alias, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/custom_speech").also { it.setMethodCallHandler(this) }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        io.execute {
            try {
                val prefs = context.getSharedPreferences("custom_speech_secure", 0)
                val value: String? = when (call.method) {
                    "read" -> prefs.getString("config", null)?.let {
                        val parts = it.split(':'); require(parts.size == 2)
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                        cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)).toString(Charsets.UTF_8)
                    }
                    "write" -> {
                        val text = call.arguments as? String
                        if (text == null) check(prefs.edit().remove("config").commit()) else {
                            require(text.length <= 16384)
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
                            val data = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
                                Base64.encodeToString(cipher.doFinal(text.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
                            check(prefs.edit().putString("config", data).commit())
                        }; null
                    }
                    else -> throw IllegalArgumentException("Unsupported vault operation")
                }
                main.post { result.success(value) }
            } catch (_: Exception) { main.post { result.error("secure_storage", "语音接口配置未保存或无法读取，请重试", null) } }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null); channel = null; io.shutdown()
    }
}
