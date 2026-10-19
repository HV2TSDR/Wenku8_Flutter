package org.mewx.wenku8_flutter

import android.content.Intent
import android.content.Context
import android.app.Activity
import android.os.Bundle
import android.os.ResultReceiver
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.PluginRegistry

/** The repository survives a detached UI while the audio engine remains alive. */
internal fun attachWenkuEnginePlugins(engine: FlutterEngine) {
    if (!engine.plugins.has(WenkuHostPlugin::class.java)) engine.plugins.add(WenkuHostPlugin())
    if (!engine.plugins.has(SystemSpeechPlugin::class.java)) engine.plugins.add(SystemSpeechPlugin())
    if (!engine.plugins.has(AppUpdatePlugin::class.java)) engine.plugins.add(AppUpdatePlugin())
    if (!engine.plugins.has(CustomSpeechConfigPlugin::class.java)) engine.plugins.add(CustomSpeechConfigPlugin())
    if (!engine.plugins.has(CloudSourceConfigPlugin::class.java)) engine.plugins.add(CloudSourceConfigPlugin())
    if (!engine.plugins.has(ReaderControlsPlugin::class.java)) engine.plugins.add(ReaderControlsPlugin())
    if (!engine.plugins.has(NetworkStatusPlugin::class.java)) engine.plugins.add(NetworkStatusPlugin())
    if (!engine.plugins.has(FrameRatePlugin::class.java)) engine.plugins.add(FrameRatePlugin())
}

class WenkuHostPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {
    companion object {
        /** Only framework types cross the release-test ABI. Plugin classes may
         * be independently renamed by the app and instrumentation shrinkers. */
        @JvmStatic fun probeCatalogForPreview(context: Context, method: String, args: Bundle, receiver: ResultReceiver) {
            fun reply(status: String) = receiver.send(Activity.RESULT_OK, Bundle().apply { putString("status", status) })
            if (context.packageName != "org.mewx.wenku8_flutter.reader_preview") { reply("NOT_ALLOWED"); return }
            Handler(Looper.getMainLooper()).post {
                try {
                    val owner = AudioServicePlugin.getFlutterEngine(context).plugins.get(WenkuHostPlugin::class.java) as WenkuHostPlugin
                    val arguments = mutableMapOf<String, Any>()
                    args.getString("action")?.let { arguments["action"] = it }
                    if (args.containsKey("library")) arguments["library"] = args.getInt("library")
                    if (args.containsKey("page")) arguments["page"] = args.getInt("page")
                    owner.readOnlyCatalogProbe(MethodCall(method, arguments), object : MethodChannel.Result {
                        override fun success(value: Any?) {
                            if (method == "hasSession") { reply(if (value == true) "PRESENT" else "ABSENT"); return }
                            val text = value?.toString()?.trim() ?: ""
                            val numeric = text.toIntOrNull()
                            val status = when {
                                text.isEmpty() -> "EMPTY"
                                numeric != null -> if (numeric in 0..99) "STATUS:$numeric" else "NUMERIC_RESPONSE"
                                text.contains("<metadata") -> "ACCOUNT_XML"
                                text.contains("<result") -> "LIST_XML:${Regex("<item\\b").findAll(text).count()}"
                                Regex("name\\s*=\\s*['\"]password['\"]", RegexOption.IGNORE_CASE).containsMatchIn(text) ||
                                    Regex("(请先|必须|需要|尚未|还未|没有).{0,8}(登录|登陆)|(登录|登陆)后").containsMatchIn(text) -> "WEBSITE_LOGIN_REQUIRED"
                                else -> {
                                    val count = Regex("(?:/book/|articleinfo.php\\?id=)(\\d+)").findAll(text).map { it.groupValues[1] }.toSet().size
                                    if (count > 0) "WEB_LIST:$count" else "OTHER_RESPONSE"
                                }
                            }
                            reply(status)
                        }
                        override fun error(code: String, message: String?, details: Any?) = reply("ERROR:$code")
                        override fun notImplemented() = reply("NOT_IMPLEMENTED")
                    })
                } catch (failure: Throwable) { reply("PROBE_FAILURE:${failure.javaClass.simpleName}") }
            }
        }
    }
    private var api: Wenku8Bridge? = null
    private var apiChannel: MethodChannel? = null
    private var toolsChannel: MethodChannel? = null
    private var tools: LocalTools? = null
    private var documents: BookDocuments? = null
    private var documentsChannel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var readerPreview = false

    /** Preview-only instrumentation uses the existing account executor, not a
     * second cookie owner. This is not registered on any external channel. */
    internal fun readOnlyCatalogProbe(call: MethodCall, result: MethodChannel.Result) {
        val allowed = call.method == "hasSession" ||
            call.method == "publicationPage" && call.argument<Int>("library") == 1 && call.argument<Int>("page") == 1 ||
            call.method == "accountRequest" && call.argument<String>("action") in setOf("action=userinfo", "action=articlelist&sort=1&page=1", "action=novellist&sort=1&page=1&t=0")
        check(readerPreview && allowed)
        (api ?: error("Account owner is not attached")).onMethodCall(call, result)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        readerPreview = binding.applicationContext.packageName == "org.mewx.wenku8_flutter.reader_preview"
        val main = Handler(Looper.getMainLooper())
        api = Wenku8Bridge(binding.applicationContext) { main.post(it) }
        apiChannel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/legacy_api").also {
            it.setMethodCallHandler(api)
        }
        toolsChannel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/local_tools").also {
            it.setMethodCallHandler { call, result ->
                val attached = tools
                if (attached != null) attached.onMethodCall(call, result)
                else result.error("NO_ACTIVITY", "This action needs the app page", null)
            }
        }
        documentsChannel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/book_documents").also {
            it.setMethodCallHandler { call, result ->
                val attached = documents
                if (attached != null) attached.onMethodCall(call, result)
                else result.error("NO_ACTIVITY", "请在文库页面执行文件操作", null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        apiChannel?.setMethodCallHandler(null)
        toolsChannel?.setMethodCallHandler(null)
        documentsChannel?.setMethodCallHandler(null)
        api?.close()
        api = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        tools = LocalTools(binding.activity)
        documents = BookDocuments(binding.activity)
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }
    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        tools?.close()
        tools = null
        documents?.close()
        documents = null
    }
    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        (tools?.onActivityResult(requestCode, resultCode, data) ?: false) ||
            (documents?.onActivityResult(requestCode, resultCode, data) ?: false)
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean =
        documents?.onRequestPermissionsResult(requestCode) ?: false
}
