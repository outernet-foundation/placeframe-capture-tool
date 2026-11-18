package org.outernet.placeframe.placeframe_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var ar: ArFrameStreamer

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ar = ArFrameStreamer(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "placeframe/ar/frames").setStreamHandler(ar)
        MethodChannel(messenger, "placeframe/ar").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "available" -> result.success(ar.available())
                    "start" -> {
                        ar.start(call.argument<Double>("interval") ?: 1.0, call.argument<Int>("quality") ?: 90)
                        result.success(null)
                    }
                    "stop" -> {
                        ar.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("arcore", e.message, null)
            }
        }
    }

    override fun onPause() {
        ar.stop()
        super.onPause()
    }
}
