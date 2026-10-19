package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Settings and status only. HighRefreshRateController remains the sole voter. */
class FrameRatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, DisplayManager.DisplayListener {
    private var activity: Activity? = null
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val manager get() = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/frame_rate")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { detach(); channel.setMethodCallHandler(null) }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        manager.registerDisplayListener(this, Handler(Looper.getMainLooper()))
    }
    private fun detach() { manager.unregisterDisplayListener(this); activity = null }
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() = detach()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    @Suppress("DEPRECATION")
    private fun display(): Display = activity?.let { if (Build.VERSION.SDK_INT >= 30) it.display else it.windowManager.defaultDisplay } ?: error("请在文库页面调整帧率")
    private fun mode(value: Display.Mode) = RefreshRatePolicy.Mode(value.modeId, value.physicalWidth, value.physicalHeight, value.refreshRate)
    private fun info(): Map<String, Any> {
        val display = display()
        return mapOf("target" to context.getSharedPreferences("frame_rate_settings", 0).getFloat("target", 0f).toDouble(),
            "current" to display.mode.refreshRate.toDouble(),
            "rates" to RefreshRatePolicy.rates(mode(display.mode), display.supportedModes.map(::mode)).map { it.toDouble() })
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "info" -> result.success(info())
                "set" -> {
                    val rate = call.argument<Number>("target")?.toFloat() ?: error("请选择帧率")
                    val display = display()
                    val supported = RefreshRatePolicy.rates(mode(display.mode), display.supportedModes.map(::mode))
                    require(rate == 0f || rate == -1f || rate.isFinite() && supported.any { kotlin.math.abs(it - rate) < .5f }) { "当前屏幕不支持此刷新率，请重新选择" }
                    check(context.getSharedPreferences("frame_rate_settings", 0).edit().putFloat("target", rate).commit()) { "帧率设置未保存，请重试" }
                    result.success(info())
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("frame_rate", error.message ?: "刷新率信息读取失败", null) }
    }
    override fun onDisplayAdded(displayId: Int) { channel.invokeMethod("changed", null) }
    override fun onDisplayRemoved(displayId: Int) { channel.invokeMethod("changed", null) }
    override fun onDisplayChanged(displayId: Int) { if (activity != null && runCatching { display().displayId }.getOrNull() == displayId) channel.invokeMethod("changed", null) }
}
