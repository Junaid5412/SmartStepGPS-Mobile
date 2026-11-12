package com.smartstep.gps

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Push notifications on Android (Google FCM).
 *
 * There is no google-services.json in this app. The four values Firebase needs (app id, API key, project id, sender id)
 * come from the school's server after sign-in and are remembered here, so Firebase can be started again when a message
 * arrives while the app is closed. The portal can change the Firebase project without a new app build.
 *
 * The server sends DATA messages (title + body); this app puts the notification on the screen itself, the same way
 * whether it is open, in the background or closed.
 */
object Push {
    private const val PREFS = "smartstep_push"
    const val CHANNEL = "school_bus"

    fun saveConfig(ctx: Context, appId: String, apiKey: String, projectId: String, senderId: String) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("app_id", appId).putString("api_key", apiKey).putString("project_id", projectId).putString("sender_id", senderId).apply()
    }

    /** Start Firebase from the remembered values. False when the server never gave any (push is not set up). */
    fun ensureApp(ctx: Context): Boolean {
        val app = ctx.applicationContext
        val p = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val appId = p.getString("app_id", "") ?: ""
        val apiKey = p.getString("api_key", "") ?: ""
        val projectId = p.getString("project_id", "") ?: ""
        val senderId = p.getString("sender_id", "") ?: ""
        if (appId.isEmpty() || apiKey.isEmpty() || projectId.isEmpty() || senderId.isEmpty()) return false
        return try {
            val running = FirebaseApp.getApps(app).firstOrNull { it.name == FirebaseApp.DEFAULT_APP_NAME }
            if (running != null) {
                // The portal moved to another Firebase project: the old one must go before the new one can start.
                if (running.options.applicationId == appId && running.options.projectId == projectId) return true
                running.delete()
            }
            FirebaseApp.initializeApp(app, FirebaseOptions.Builder()
                .setApplicationId(appId).setApiKey(apiKey).setProjectId(projectId).setGcmSenderId(senderId).build())
            true
        } catch (e: Exception) {
            false
        }
    }

    fun channel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL) != null) return
        val ch = NotificationChannel(CHANNEL, "School bus", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "Pick-up, drop-off and absence of your child"
        nm.createNotificationChannel(ch)
    }

    fun allowed(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return NotificationManagerCompat.from(ctx).areNotificationsEnabled()
    }

    fun show(ctx: Context, id: Int, title: String, body: String) {
        if (!allowed(ctx)) return
        channel(ctx)
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("open", "notifications")
        }
        val tap = if (open == null) null else PendingIntent.getActivity(ctx, id, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_bus)
            .setColor(0xFF1565C0.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(id, n)
        } catch (e: SecurityException) {
            // the permission was taken away between the check and now
        }
    }
}

class PushService : FirebaseMessagingService() {
    override fun onCreate() {
        super.onCreate()
        Push.ensureApp(this)        // the app was closed: Firebase has to be started from the remembered values
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val d = message.data
        val title = d["title"] ?: message.notification?.title ?: return
        val body = d["body"] ?: message.notification?.body ?: ""
        val id = d["notification_id"]?.toIntOrNull() ?: (System.currentTimeMillis() % Int.MAX_VALUE).toInt()
        Push.show(this, id, title, body)
    }

    override fun onNewToken(token: String) {
        // Google gave this phone a new address. The app sends its current one to the server every time it opens
        // (PushService in Dart), so it is only remembered here.
        getSharedPreferences("smartstep_push", MODE_PRIVATE).edit().putString("token", token).apply()
    }
}
