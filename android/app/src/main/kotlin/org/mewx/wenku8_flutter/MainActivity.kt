package org.mewx.wenku8_flutter

import android.content.res.Configuration
import android.os.Bundle
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    private var refreshRate: HighRefreshRateController? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        refreshRate = HighRefreshRateController(this)
    }

    override fun onResume() {
        super.onResume()
        refreshRate?.start()
    }

    override fun onPause() {
        (flutterEngine?.plugins?.get(ReaderControlsPlugin::class.java) as? ReaderControlsPlugin)?.suspend()
        refreshRate?.stop()
        super.onPause()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        (flutterEngine?.plugins?.get(ReaderControlsPlugin::class.java) as? ReaderControlsPlugin)?.dispatch(event) == true || super.dispatchKeyEvent(event)

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) refreshRate?.refresh()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        refreshRate?.refresh()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attachWenkuEnginePlugins(flutterEngine)
    }

    override fun onDestroy() {
        refreshRate?.stop()
        refreshRate = null
        super.onDestroy()
    }
}
