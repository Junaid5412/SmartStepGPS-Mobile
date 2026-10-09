package com.smartstep.gps

import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity

// Edge-to-edge on every Android version, not only on Android 15+ where the system forces it - this
// is what Google Play asks for ("Edge-to-edge may not display for all users"). The Flutter side keeps
// content clear of the status and navigation bars (see main.dart).
// FlutterFragmentActivity (a ComponentActivity) is what makes enableEdgeToEdge() available.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
    }
}
