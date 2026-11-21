package com.unifiedtik

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hv/native").setMethodCallHandler { call, result ->
            when (call.method) {
                // "Samsung SM-A155F": shown in the website as the device that reaches the router
                "deviceName" -> result.success(listOf(Build.MANUFACTURER ?: "", Build.MODEL ?: "")
                    .filter { it.isNotBlank() }.joinToString(" ").trim())
                // Router announcements (MNDP) arrive as broadcasts; some phones drop them without this lock.
                "multicast" -> {
                    val on = call.arguments as? Boolean ?: false
                    try {
                        if (on) {
                            if (lock == null) {
                                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                lock = wm.createMulticastLock("hv-mndp").apply { setReferenceCounted(false); acquire() }
                            }
                        } else {
                            lock?.release(); lock = null
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try { lock?.release() } catch (_: Exception) {}
        lock = null
        super.onDestroy()
    }
}
