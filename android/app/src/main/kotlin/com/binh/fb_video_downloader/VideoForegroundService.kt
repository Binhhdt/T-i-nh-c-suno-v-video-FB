package com.binh.fb_video_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class VideoForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL, "Tải video Facebook", NotificationManager.IMPORTANCE_LOW
            ))
        }
        startForeground(ID, notification(0, null))
        val power = getSystemService(PowerManager::class.java)
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TaiVideo:Facebook").apply {
            acquire(6 * 60 * 60 * 1000L)
        }
        current = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    internal fun update(count: Int, percent: Int?) {
        getSystemService(NotificationManager::class.java).notify(ID, notification(count, percent))
    }

    @Suppress("DEPRECATION")
    private fun notification(count: Int, percent: Int?): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Tải video Facebook")
            .setContentText(if (count == 0) "Đang chuẩn bị" else "$count video trong hàng đợi")
            .setOnlyAlertOnce(true).setOngoing(true).setContentIntent(open)
            .setProgress(100, percent ?: 0, percent == null).build()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        (application as VideoApplication).videoBridge.serviceTimeout()
        stopSelf()
    }

    override fun onDestroy() {
        if (current === this) current = null
        if (wakeLock?.isHeld == true) wakeLock?.release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "facebook_video_downloads"
        private const val ID = 7842
        internal var current: VideoForegroundService? = null
            private set
    }
}
