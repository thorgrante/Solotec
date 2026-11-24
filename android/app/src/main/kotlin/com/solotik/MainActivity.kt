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
