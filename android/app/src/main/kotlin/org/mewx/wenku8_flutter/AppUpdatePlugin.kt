package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Installs only newer, same-package APKs signed by the app's signing lineage. */
class AppUpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var packages: UpdatePackages
    private var activity: Activity? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        packages = UpdatePackages(context)
        attached = true
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/app_updates")
        channel.setMethodCallHandler(this)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> try {
                val current = packages.installed()
                result.success(mapOf("package" to context.packageName, "version" to current.versionName, "build" to packages.code(current), "abis" to Build.SUPPORTED_ABIS.toList()))
            } catch (_: Exception) { result.error("VERSION", "无法读取当前应用版本", null) }
            "allowInstalls" -> withActivity(result) { page ->
                if (Build.VERSION.SDK_INT >= 26) page.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")))
                result.success(null)
            }
            "openRelease" -> withActivity(result) { page ->
                val uri = Uri.parse(call.arguments as? String ?: "")
                require(uri.scheme == "https" && uri.host == "github.com" && uri.userInfo == null && uri.path.orEmpty().contains("/releases/"))
                page.startActivity(Intent(Intent.ACTION_VIEW, uri))
                result.success(null)
            }
            "inspect", "install" -> {
                val path = call.argument<String>("path") ?: ""
                val version = call.argument<String>("version") ?: ""
                val build = call.argument<Number>("build")?.toLong()
                io.execute {
                    try {
                        val update = if (call.method == "inspect") packages.inspect(path, version, build)
                            else packages.forInstall(path, version, build)
                        main.post {
                            if (!attached) return@post
                            if (call.method == "inspect") {
                                result.success(update.metadata())
                                return@post
                            }
                            withActivity(result) { page ->
                                if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
                                    result.success("permission")
                                } else {
                                    page.startActivity(packages.installIntent(update))
                                    result.success("opened")
                                }
                            }
                        }
                    } catch (failure: Exception) {
                        main.post { if (attached) result.error("APK_REJECTED", failure.message ?: "安装包无法验证，请重新下载", null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun withActivity(result: MethodChannel.Result, action: (Activity) -> Unit) {
        val page = activity
        if (page == null || page.isFinishing) result.error("NO_ACTIVITY", "请在应用内重试", null)
        else try { action(page) } catch (_: Exception) { result.error("OPEN", "系统页面无法打开，请重试", null) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        io.shutdownNow()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
}
