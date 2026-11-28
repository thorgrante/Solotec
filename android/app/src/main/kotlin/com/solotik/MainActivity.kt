package com.solotik

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var lock: WifiManager.MulticastLock? = null
    private val ui = Handler(Looper.getMainLooper())

    // When the shop Wi-Fi has no internet before logging in (the hotspot), Android sends the app's traffic over
    // mobile data, where the router (192.168.x.x) cannot be reached. Connections to the router are therefore made
    // on the Wi-Fi network itself.
    private fun lan(): Network? {
        val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        @Suppress("DEPRECATION") val all = cm.allNetworks
        fun has(n: Network, t: Int) = try { cm.getNetworkCapabilities(n)?.hasTransport(t) == true } catch (e: Exception) { false }
        return all.firstOrNull { has(it, NetworkCapabilities.TRANSPORT_WIFI) } ?: all.firstOrNull { has(it, NetworkCapabilities.TRANSPORT_ETHERNET) }
    }

    private fun lanSocket(n: Network, host: String, port: Int, ms: Int): Socket {
        val s = n.socketFactory.createSocket()
        try { s.connect(InetSocketAddress(n.getByName(host), port), ms); s.tcpNoDelay = true; return s }
        catch (e: Exception) { try { s.close() } catch (_: Exception) {}; throw e }
    }

    private fun pipe(i: InputStream, o: OutputStream, a: Socket, b: Socket) = thread(isDaemon = true) {
        val buf = ByteArray(16384)
        try { while (true) { val n = i.read(buf); if (n < 0) break; o.write(buf, 0, n); o.flush() } } catch (_: Exception) {}
        try { a.close() } catch (_: Exception) {}
        try { b.close() } catch (_: Exception) {}
    }

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
                // A connection to a device on the shop network, made on the Wi-Fi. Answers a local port that the app
                // connects to (127.0.0.1), or null when there is no Wi-Fi (the app then connects as usual).
                "lanTunnel" -> {
                    val a = call.arguments as? Map<*, *>
                    val host = a?.get("host") as? String ?: ""
                    val port = (a?.get("port") as? Number)?.toInt() ?: 0
                    val ms = (a?.get("ms") as? Number)?.toInt() ?: 8000
                    val n = lan()
                    if (n == null || host.isEmpty() || port <= 0) { result.success(null); return@setMethodCallHandler }
                    val answered = AtomicBoolean(false)
                    thread(isDaemon = true) {
                        var up: Socket? = null
                        var ss: ServerSocket? = null
                        try {
                            up = lanSocket(n, host, port, ms)
                            ss = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 15000 }
                            val local = ss.localPort
                            answered.set(true); ui.post { result.success(local) }
                            val down = ss.accept(); ss.close(); down.tcpNoDelay = true
                            pipe(up.getInputStream(), down.getOutputStream(), up, down)
                            pipe(down.getInputStream(), up.getOutputStream(), down, up)
                        } catch (e: Exception) {
                            try { up?.close() } catch (_: Exception) {}
                            try { ss?.close() } catch (_: Exception) {}
                            if (!answered.getAndSet(true)) { val m = e.message ?: e.javaClass.simpleName; ui.post { result.error("connect", m, null) } }
                        }
                    }
                }
                // Is a port open on a device on the shop network (found on the Wi-Fi)? null when there is no Wi-Fi.
                "lanProbe" -> {
                    val a = call.arguments as? Map<*, *>
                    val host = a?.get("host") as? String ?: ""
                    val port = (a?.get("port") as? Number)?.toInt() ?: 0
                    val ms = (a?.get("ms") as? Number)?.toInt() ?: 800
                    val n = lan()
                    if (n == null || host.isEmpty() || port <= 0) { result.success(null); return@setMethodCallHandler }
                    thread(isDaemon = true) {
                        val ok = try { lanSocket(n, host, port, ms).close(); true } catch (_: Exception) { false }
                        ui.post { result.success(ok) }
                    }
                }
                // A file the page made (tickets PDF...): kept in Downloads and opened in its own app, in its own
                // window (so closing the PDF never means closing Solotik). false: the app shares it instead.
                "saveOpen" -> {
                    val a = call.arguments as? Map<*, *>
                    val path = a?.get("path") as? String ?: ""; val name = a?.get("name") as? String ?: "file"
                    val mime = a?.get("mime") as? String ?: "application/octet-stream"
                    if (Build.VERSION.SDK_INT < 29 || path.isEmpty()) { result.success(false); return@setMethodCallHandler }
                    thread(isDaemon = true) {
                        try {
                            val v = android.content.ContentValues().apply {
                                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
                                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS + "/Solotik")
                            }
                            val uri = contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, v) ?: throw Exception("no place to save")
                            contentResolver.openOutputStream(uri)!!.use { o -> java.io.File(path).inputStream().use { it.copyTo(o) } }
                            ui.post {
                                try {
                                    startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW).setDataAndType(uri, mime)
                                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_MULTIPLE_TASK or android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                    result.success(true)
                                } catch (e: Exception) { result.success(false) }
                            }
                        } catch (e: Exception) { ui.post { result.success(false) } }
                    }
                }
                "alertsStatus" -> { try { result.success(AlertService.status(applicationContext)) } catch (e: Exception) { result.error("alerts", e.message, null) } }
                "alertsSettings" -> { try { AlertService.settings(this); result.success(true) } catch (e: Exception) { result.error("alerts", e.message, null) } }
                // Ticket alerts while the app is closed: {on, server, key}
                "alerts" -> {
                    val a = call.arguments as? Map<*, *>
                    val on = a?.get("on") as? Boolean ?: false
                    try {
                        if (on) {
                            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != android.content.pm.PackageManager.PERMISSION_GRANTED)
                                requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 7)
                            AlertService.start(applicationContext, a?.get("server") as? String ?: "", a?.get("key") as? String ?: "")
                            askBattery()
                        } else AlertService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) { result.error("alerts", e.message ?: e.javaClass.simpleName, null) }
                }
                else -> result.notImplemented()
            }
        }
    }

    // Some phones stop background work to save battery: ask once to let the alert watcher run.
    private fun askBattery() {
        if (Build.VERSION.SDK_INT < 23) return
        val p = getSharedPreferences(AlertService.PREFS, Context.MODE_PRIVATE)
        if (p.getBoolean("askedBattery", false)) return
        p.edit().putBoolean("askedBattery", true).apply()
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName))
                startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:$packageName")))
        } catch (_: Exception) {}
    }

    override fun onResume() { super.onResume(); AlertService.foreground = true; askNotifications() }

    // Android 13 and later: the app must ask before it may show any notification (once; after that, the phone's settings)
    private fun askNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission("android.permission.POST_NOTIFICATIONS") == android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val p = getSharedPreferences(AlertService.PREFS, Context.MODE_PRIVATE)
        if (p.getInt("askedNotify", 0) >= 2) return
        p.edit().putInt("askedNotify", p.getInt("askedNotify", 0) + 1).apply()
        requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 7)
    }
    override fun onPause() { AlertService.foreground = false; super.onPause() }

    override fun onDestroy() {
        try { lock?.release() } catch (_: Exception) {}
        lock = null
        super.onDestroy()
    }
}
