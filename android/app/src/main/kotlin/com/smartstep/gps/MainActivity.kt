package com.smartstep.gps

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Edge-to-edge on every Android version, not only on Android 15+ where the system forces it - this
// is what Google Play asks for ("Edge-to-edge may not display for all users"). The Flutter side keeps
// content clear of the status and navigation bars (see main.dart).
// FlutterFragmentActivity (a ComponentActivity) is what makes enableEdgeToEdge() available.
class MainActivity : FlutterFragmentActivity() {
    private var askResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
    }

    // Push notifications (Push.kt). Channel "smartstep/push":
    //   register {app_id, api_key, project_id, sender_id} -> this phone's FCM token, or null when it cannot get one
    //   allowed                                            -> may this app show notifications?
    //   ask                                                -> ask for the notification permission (Android 13+) -> allowed?
    //   unregister                                         -> give the token up (sign out)
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smartstep/push").setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> {
                    Push.saveConfig(this, call.argument<String>("app_id") ?: "", call.argument<String>("api_key") ?: "",
                        call.argument<String>("project_id") ?: "", call.argument<String>("sender_id") ?: "")
                    if (!Push.ensureApp(this)) { result.success(null); return@setMethodCallHandler }
                    Push.channel(this)
                    try {
                        FirebaseMessaging.getInstance().token.addOnCompleteListener { t ->
                            result.success(if (t.isSuccessful) t.result else null)
                        }
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "allowed" -> result.success(Push.allowed(this))
                "ask" -> {
                    if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        askResult?.success(false)
                        askResult = result
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4711)
                    } else {
                        result.success(Push.allowed(this))
                    }
                }
                "unregister" -> {
                    try {
                        if (Push.ensureApp(this)) FirebaseMessaging.getInstance().deleteToken()
                    } catch (e: Exception) { /* nothing to give up */ }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4711) {
            askResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            askResult = null
        }
    }
}
