package com.colanas.os

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaStyleNotificationHelper

/**
 * 视频的媒体通知 / 前台服务。
 *
 * 为什么不用 `MediaSessionService` 的默认通知：
 * 默认实现依赖它内部的 MediaNotificationManager 在「播放状态变化」时自己
 * startForeground，实测在部分国产 ROM（小米 / HyperOS）上媒体卡出不来。
 * 这里改成自己持有 MediaSession + MediaStyle 通知，播放时明确
 * `startForeground`，暂停时保留通知，退出播放页时移除 —— 行为完全可控。
 *
 * 通知里的播放 / 暂停按钮通过 PendingIntent 回到本服务；锁屏 / 系统媒体面板
 * 则通过 MediaSession token 直接控制 ExoPlayer。
 */
class VideoMediaSessionService : Service() {
    private var mediaSession: MediaSession? = null
    private var listener: Player.Listener? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        // Android 8+ 用 startForegroundService 拉起时，5 秒内必须进前台，
        // 否则系统直接抛 ForegroundServiceDidNotStartInTimeException。
        // 先顶上一条通知（此时 MediaSession 还没建好，只是普通样式），
        // 会话建好后的 push() 会把它刷成 MediaStyle 媒体卡。
        startForegroundCompat()
        val player = VideoPlaybackHolder.player
        if (player == null) {
            Log.w(TAG, "服务创建时播放器还没就绪，直接退出")
            stopSelf()
            return
        }
        mediaSession =
            MediaSession.Builder(this, player)
                .setSessionActivity(launchIntent())
                .build()
        VideoPlaybackHolder.mediaSession = mediaSession
        listener =
            object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) = push()

                override fun onPlaybackStateChanged(playbackState: Int) = push()

                override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) = push()
            }.also { player.addListener(it) }
        Log.i(TAG, "媒体服务已创建；开始挂通知")
        push()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_TOGGLE) {
            val player = VideoPlaybackHolder.player
            if (player != null) {
                if (player.isPlaying) player.pause() else player.play()
            }
            push()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        VideoPlaybackHolder.player?.pause()
        stopSelf()
    }

    override fun onDestroy() {
        val player = VideoPlaybackHolder.player
        listener?.let { player?.removeListener(it) }
        listener = null
        if (VideoPlaybackHolder.mediaSession === mediaSession) {
            VideoPlaybackHolder.mediaSession = null
        }
        mediaSession?.release()
        mediaSession = null
        runCatching {
            stopForeground(STOP_FOREGROUND_REMOVE)
            NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        }
        super.onDestroy()
    }

    /**
     * 播放 / 暂停都保持前台通知。
     *
     * 暂停时不再 `stopForeground`：服务一旦退出前台，系统会撤掉媒体卡，
     * 用户点通知里的「继续」也会因为进程被冻结而落空。持续前台 + 常驻通知
     * 才能让状态栏的卡片一直在，直到退出播放页（`dispose` → stopService）。
     */
    private fun push() {
        try {
            startForegroundCompat()
        } catch (error: Exception) {
            // 没有通知权限 / ROM 限制时不要崩：画面播放不受影响
            Log.w(TAG, "媒体通知更新失败", error)
        }
    }

    private fun startForegroundCompat() {
        val notification = buildNotification(VideoPlaybackHolder.player?.isPlaying == true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(playing: Boolean): Notification {
        val player = VideoPlaybackHolder.player
        val title =
            player?.currentMediaItem?.mediaMetadata?.title?.toString()?.takeIf { it.isNotBlank() }
                ?: "视频"
        val toggle =
            PendingIntent.getService(
                this,
                1,
                Intent(this, VideoMediaSessionService::class.java).setAction(ACTION_TOGGLE),
                pendingFlags(),
            )
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_video)
                .setContentTitle(title)
                .setContentText(if (playing) "正在播放" else "已暂停")
                .setContentIntent(launchIntent())
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                // 前台服务通知：暂停后也要留在通知栏，否则媒体卡消失、无处点继续
                .setOngoing(true)
                .setSilent(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
                .addAction(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "暂停" else "继续",
                    toggle,
                )
        mediaSession?.let {
            builder.setStyle(
                MediaStyleNotificationHelper.MediaStyle(it).setShowActionsInCompactView(0),
            )
        }
        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel =
            NotificationChannel(CHANNEL_ID, "视频播放", NotificationManager.IMPORTANCE_LOW).apply {
                description = "电影 / 电视剧的播放控制"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        manager.createNotificationChannel(channel)
    }

    /** 点通知 / 锁屏媒体卡回到 App */
    private fun launchIntent(): PendingIntent {
        val intent =
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        return PendingIntent.getActivity(this, 0, intent, pendingFlags())
    }

    private fun pendingFlags(): Int =
        PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }

    companion object {
        private const val TAG = "ColaNasMedia3"
        private const val CHANNEL_ID = "video_playback"
        private const val NOTIFICATION_ID = 0x0C01
        const val ACTION_TOGGLE = "com.colanas.os.video.TOGGLE"
    }
}
