package com.colanas.os

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** 下载通知栏状态。MainActivity 与 Service 同进程，直接共享这份内存。 */
object DownloadNotificationState {
    @Volatile var title: String = "正在下载"
    @Volatile var text: String = ""
    @Volatile var progress: Int = -1
    @Volatile var max: Int = 100
}

/**
 * 离线下载前台服务（dataSync）。
 *
 * 为什么单独一个服务、不复用 [BackupForegroundService]：一个 Service 只能持有
 * **一个**前台通知，两个功能同时跑会互相顶掉，`stop()` 还会把对方一起收掉。
 * 下载和相册备份互不相干，各用各的通道最省心（代价是一百来行几乎一样的样板）。
 *
 * 只做两件事：把进程保活、显示「下载中 + 进度」。真正的下载在 Dart 主 isolate 里
 * （单连接 Range + 边下边算 sha256），这里不碰 IO —— 否则要维护两套实现。
 * 没有它，手机一息屏 App 就被冻结，下载循环断掉、回来还得手动点一次。
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "com.colanas.os.download"
        private const val NOTIFICATION_ID = 4202

        @Volatile private var live: DownloadForegroundService? = null

        fun start(ctx: Context, title: String, text: String) {
            DownloadNotificationState.title = title
            DownloadNotificationState.text = text
            DownloadNotificationState.progress = -1
            DownloadNotificationState.max = 100
            val cur = live
            if (cur != null) {
                cur.refresh()
                return
            }
            launch(ctx)
        }

        fun update(ctx: Context, text: String, progress: Int, max: Int) {
            DownloadNotificationState.text = text
            DownloadNotificationState.progress = progress
            DownloadNotificationState.max = max.coerceAtLeast(1)
            val cur = live
            if (cur != null) {
                cur.refresh()
                return
            }
            // 服务被系统回收过：重新拉起，通知照常显示
            launch(ctx)
        }

        fun stop(ctx: Context) {
            live?.shutdown()
            try {
                ctx.stopService(Intent(ctx, DownloadForegroundService::class.java))
            } catch (_: Exception) {
                // 服务本来就没在跑
            }
        }

        private fun launch(ctx: Context) {
            val i = Intent(ctx, DownloadForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
            } catch (_: Exception) {
                // 后台启动被系统拒绝：Dart 侧照常下载，只是这次没有通知栏
            }
        }
    }

    private var inForeground = false

    override fun onCreate() {
        super.onCreate()
        live = this
        createChannelIfNeeded()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground 必须在 startForegroundService 之后 5s 内调用
        if (!inForeground) foreground()
        return START_STICKY
    }

    private fun refresh() {
        if (!inForeground) {
            foreground()
            return
        }
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, buildNotification())
        } catch (_: Exception) {
            // 通知权限被关掉时忽略；前台服务仍在保活
        }
    }

    private fun foreground() {
        try {
            val n = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            inForeground = true
        } catch (_: Exception) {
            // 主动收掉，避免系统 5s 后按 "did not call startForeground" 杀进程
            stopSelf()
        }
    }

    fun shutdown() {
        @Suppress("DEPRECATION")
        stopForeground(true)
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
        inForeground = false
        stopSelf()
    }

    override fun onDestroy() {
        live = null
        inForeground = false
        super.onDestroy()
    }

    private fun createChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            "离线下载",
            NotificationManager.IMPORTANCE_LOW,
        )
        ch.description = "下载视频到本机的进度"
        ch.setShowBadge(false)
        mgr.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        var pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingFlags = pendingFlags or PendingIntent.FLAG_IMMUTABLE
        }
        val pi = PendingIntent.getActivity(this, 0, launch, pendingFlags)
        val st = DownloadNotificationState
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(st.title)
            .setContentText(st.text)
            .setContentIntent(pi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(st.max, st.progress.coerceAtLeast(0), st.progress < 0)
            .build()
    }
}
