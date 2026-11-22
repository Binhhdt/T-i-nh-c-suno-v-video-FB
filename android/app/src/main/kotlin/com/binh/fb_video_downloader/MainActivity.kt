package com.binh.fb_video_downloader

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as VideoApplication).videoEngine

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val bridge = (application as VideoApplication).videoBridge
        bridge.activity = this
        if (savedInstanceState == null) bridge.acceptShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        (application as VideoApplication).videoBridge.acceptShare(intent)
    }

    @Deprecated("Called by the Android document picker on older API levels")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        (application as VideoApplication).videoBridge.picked(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        val bridge = (application as VideoApplication).videoBridge
        if (bridge.activity === this) bridge.activity = null
        super.onDestroy()
    }
}
