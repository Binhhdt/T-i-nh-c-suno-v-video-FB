package com.binh.fb_video_downloader

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

internal class VideoBridge(private val app: VideoApplication, messenger: BinaryMessenger) {
    var activity: MainActivity? = null
    private val channel = MethodChannel(messenger, "com.binh.fb_video_downloader/video")
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newFixedThreadPool(3)
    private val storage = VideoStorage(app)
    private var pendingShare: String? = null
    private var picker: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val host = activity ?: error("Activity unavailable")
                        val service = Intent(app, VideoForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) host.startForegroundService(service)
                        else host.startService(service)
                        result.success(null)
                    }
                    "stop" -> {
                        app.stopService(Intent(app, VideoForegroundService::class.java))
                        result.success(null)
                    }
                    "progress" -> {
                        VideoForegroundService.current?.update(call.argument<Int>("count") ?: 0,
                            call.argument<Int>("percent"))
                        result.success(null)
                    }
                    "cookie" -> result.success(CookieManager.getInstance().getCookie("https://www.facebook.com"))
                    "takeShare" -> {
                        result.success(pendingShare)
                        pendingShare = null
                    }
                    "sdk" -> result.success(Build.VERSION.SDK_INT)
                    "pickFolder" -> pickFolder(result)
                    "inspect" -> work(result) { storage.inspect(call.arguments as String) }
                    "recoverExport" -> work(result) { storage.recover(call.arguments as String) }
                    "export" -> work(result) {
                        storage.export(call.argument<String>("source")!!, call.argument<String>("name")!!,
                            call.argument<String>("id")!!, call.argument<String>("destination"))
                    }
                    "forgetExport" -> work(result) { storage.forget(call.arguments as String) }
                    "delete" -> work(result) { storage.delete(call.arguments as String) }
                    "open", "share" -> {
                        val uri = Uri.parse(call.arguments as String)
                        val host = activity ?: error("Activity unavailable")
                        val share = call.method == "share"
                        val intent = if (share) {
                            Intent(Intent.ACTION_SEND).setType("video/mp4")
                                .putExtra(Intent.EXTRA_STREAM, uri)
                        } else Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/mp4")
                        intent.clipData = ClipData.newRawUri("Video", uri)
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        host.startActivity(if (share) Intent.createChooser(intent, "Chia sẻ video") else intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("android", "Không thực hiện được thao tác trên Android.", null)
            }
        }
    }

    private fun work(result: MethodChannel.Result, action: () -> Any?) {
        workers.execute {
            try {
                val output = action()
                main.post { result.success(output) }
            } catch (e: VideoStorage.Failure) {
                main.post { result.error("storage", e.message, null) }
            } catch (_: Exception) {
                main.post { result.error("storage", "Không đọc hoặc ghi được video trên thiết bị.", null) }
            }
        }
    }

    fun serviceTimeout() = channel.invokeMethod("serviceTimeout", null)

    fun acceptShare(intent: Intent) {
        if (intent.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) {
            val link = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.take(8192)?.toString()
            if (!link.isNullOrBlank()) {
                pendingShare = link
                channel.invokeMethod("sharedLink", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun pickFolder(result: MethodChannel.Result) {
        val host = activity ?: error("Activity unavailable")
        check(picker == null)
        host.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        ), PICK_FOLDER)
        picker = result
    }

    fun picked(request: Int, code: Int, intent: Intent?) {
        if (request != PICK_FOLDER) return
        val result = picker ?: return
        picker = null
        val uri = intent?.data
        if (code != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val flags = intent.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            check(flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0)
            app.contentResolver.takePersistableUriPermission(uri, flags)
            result.success(mapOf("uri" to uri.toString(), "label" to storage.folderLabel(uri)))
        } catch (_: Exception) {
            result.error("folder", "Android không cấp quyền ghi vào thư mục đã chọn.", null)
        }
    }

    companion object {
        private const val PICK_FOLDER = 7843
    }
}
