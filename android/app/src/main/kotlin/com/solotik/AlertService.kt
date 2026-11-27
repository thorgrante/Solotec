package com.solotik

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

// Pop-up alerts with the Solotik tune while the app is closed: a small watcher (with its own quiet
// "watching" notification, which Android requires) asks the server every 15 seconds for new alerts
// (GET /api/alerts/feed with this phone's alerts key) and shows each one.
class AlertService : Service() {
    companion object {
        const val PREFS = "hv-alerts"
        private const val WATCH = "hv-watch"
        private const val TICKETS = "hv-tickets-tune"
        @Volatile var foreground = false // the app is on screen: it shows the alert itself
        @Volatile private var running = false

        fun start(c: Context, server: String, key: String) {
            c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean("on", true).putString("server", server.trimEnd('/')).putString("key", key).apply()
            val i = Intent(c, AlertService::class.java)
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
        }

        fun stop(c: Context) {
            c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("on", false).apply()
            c.stopService(Intent(c, AlertService::class.java))
        }
    }

    private var wake: PowerManager.WakeLock? = null

    private fun channels() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
        nm.createNotificationChannel(NotificationChannel(WATCH, "Watching for tickets", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Keeps ticket alerts working while the app is closed"; setShowBadge(false) })
        nm.createNotificationChannel(NotificationChannel(TICKETS, "Tickets and routers", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "A ticket connects a device"
            setSound(Uri.parse("android.resource://$packageName/raw/solotik"),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            enableVibration(true) })
    }

    private fun openApp(): PendingIntent = PendingIntent.getActivity(this, 0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun builder(channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else @Suppress("DEPRECATION") Notification.Builder(this)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        channels()
        val n = builder(WATCH).setSmallIcon(R.mipmap.ic_launcher).setContentTitle("Solotik")
            .setContentText("Watching for tickets that connect").setContentIntent(openApp()).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        if (!running) {
            running = true
            try { wake = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "solotik:alerts").apply { acquire() } } catch (_: Exception) {}
            thread(isDaemon = true) { loop() }
        }
        return START_STICKY
    }

    private fun loop() {
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        while (running && p.getBoolean("on", false)) {
            try { poll(p) } catch (_: Exception) { /* no internet just now: next turn */ }
            try { Thread.sleep(15000) } catch (_: InterruptedException) { break }
        }
        running = false
        stopSelf()
    }

    private fun poll(p: android.content.SharedPreferences) {
        val server = p.getString("server", "") ?: ""; val key = p.getString("key", "") ?: ""
        if (server.isEmpty() || key.isEmpty()) return
        val after = p.getLong("after", -1)
        val c = URL("$server/api/alerts/feed" + (if (after >= 0) "?after=$after" else "")).openConnection() as HttpURLConnection
        c.connectTimeout = 10000; c.readTimeout = 15000; c.setRequestProperty("X-Alert-Key", key); c.setRequestProperty("Accept", "application/json")
        try {
            if (c.responseCode == 401) { p.edit().putBoolean("on", false).apply(); return } // the key was withdrawn
            if (c.responseCode != 200) return
            val j = JSONObject(c.inputStream.bufferedReader().readText())
            val ev = j.optJSONArray("events")
            var top = j.optLong("last", 0)
            if (ev != null) for (i in 0 until ev.length()) {
                val e = ev.getJSONObject(i); val id = e.optLong("id")
                if (!foreground) show(id, e.optString("title"), e.optString("body"))
                if (i == ev.length() - 1 && ev.length() >= 50) top = id // more to come
            }
            p.edit().putLong("after", top).apply()
        } finally { c.disconnect() }
    }

    private fun show(id: Long, title: String, body: String) {
        val n = builder(TICKETS).setSmallIcon(R.mipmap.ic_launcher).setContentTitle(title).setContentText(body)
            .setContentIntent(openApp()).setAutoCancel(true)
        if (Build.VERSION.SDK_INT < 26) {
            @Suppress("DEPRECATION") n.setSound(Uri.parse("android.resource://$packageName/raw/solotik"))
            @Suppress("DEPRECATION") n.setPriority(Notification.PRIORITY_HIGH)
        }
        try { (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify((1000 + (id % 100000)).toInt(), n.build()) } catch (_: SecurityException) { /* alerts not allowed on this phone */ }
    }

    override fun onDestroy() {
        running = false
        try { wake?.release() } catch (_: Exception) {}
        wake = null
        super.onDestroy()
    }
}

// After the phone restarts, the watcher comes back by itself (when alerts are on).
class AlertBoot : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        val p = c.getSharedPreferences(AlertService.PREFS, Context.MODE_PRIVATE)
        if (!p.getBoolean("on", false)) return
        try { val s = Intent(c, AlertService::class.java); if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(s) else c.startService(s) } catch (_: Exception) {}
    }
}
