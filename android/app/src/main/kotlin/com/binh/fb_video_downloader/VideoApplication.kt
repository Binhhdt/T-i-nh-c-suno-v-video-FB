package com.binh.fb_video_downloader

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

class VideoApplication : Application() {
    internal lateinit var videoBridge: VideoBridge
        private set

    val videoEngine: FlutterEngine by lazy {
        FlutterEngine(this).also { engine ->
            videoBridge = VideoBridge(this, engine.dartExecutor.binaryMessenger)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }
}
