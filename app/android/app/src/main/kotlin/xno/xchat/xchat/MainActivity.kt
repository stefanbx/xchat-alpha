package xno.xchat.xchat

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val secureChannel = "xchat/secure"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // FLAG_SECURE gate for disappearing photos: while one is on screen, block OS screenshots +
        // screen recording and hide the window from the recents thumbnail. It CANNOT stop a second
        // camera photographing the screen — no app can — and the Flutter UI says so.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "on" -> {
                    runOnUiThread { window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) }
                    result.success(true)
                }
                "off" -> {
                    runOnUiThread { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
