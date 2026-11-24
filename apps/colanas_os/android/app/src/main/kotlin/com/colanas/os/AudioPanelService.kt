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
import android.os.SystemClock
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.media.app.NotificationCompat as MediaNotificationCompat

/**
 * 音乐 / AI 播客的通知栏、锁屏媒体卡。
 *
 * 为什么不用 `audio_service` 自动生成的通知：和视频是同一个坑
 * （见 [VideoMediaSessionService]）—— 第三方库自动挂的媒体通知在部分国产 ROM 上
 * 根本不显示（用户实测：通知权限已给、卸载重装也没有状态栏播放器）。
 * 这里自己持有 MediaSession + MediaStyle 通知，播放开始时明确 `startForeground`，
 * 与已验证可用的视频媒体卡走同一套做法。
 *
 * 播放本身仍在 Dart 侧（media_kit），本服务只负责画面板：面板 / 锁屏 / 耳机键
 * 的命令通过 [AudioPanel.onCommand] 交回 Dart，播放链路一行没动。
 */
class AudioPanelService : Service() {
    private var session: MediaSessionCompat? = null

    override fun onCreate() {
        super.onCreate()
        AudioPanel.service = this
        ensureChannel()
        val mediaSession =
            MediaSessionCompat(this, "ColaNasAudio").apply {
                setFlags(
                    MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                        MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
                )
                setSessionActivity(launchIntent())
                setCallback(
                    object : MediaSessionCompat.Callback() {
                        override fun onPlay() = AudioPanel.dispatch("play")

                        override fun onPause() = AudioPanel.dispatch("pause")

                        override fun onStop() = AudioPanel.dispatch("stop")

                        override fun onSkipToNext() = AudioPanel.dispatch("next")

                        override fun onSkipToPrevious() = AudioPanel.dispatch("previous")

                        override fun onSeekTo(pos: Long) = AudioPanel.dispatch("seek", pos)
                    },
                )
                isActive = true
            }
        session = mediaSession
        // Android 8+ 用 startForegroundService 拉起时 5 秒内必须进前台，
        // 否则系统抛 ForegroundServiceDidNotStartInTimeException。
        try {
            startForegroundCompat()
        } catch (error: Exception) {
            // 没有通知权限时前台服务照常跑（通知不可见），不能因此崩掉播放
            Log.w(TAG, "媒体通知创建失败", error)
        }
        refresh()
        Log.i(TAG, "音频媒体服务已创建：title=${AudioPanel.title}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 通知上的按钮走这里（比 MediaSession 回调更直接，不受会话抢占影响）
        when (intent?.action) {
            ACTION_TOGGLE -> AudioPanel.dispatch("toggle")
            ACTION_PREVIOUS -> AudioPanel.dispatch("previous")
            ACTION_NEXT -> AudioPanel.dispatch("next")
            ACTION_STOP -> AudioPanel.dispatch("stop")
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (AudioPanel.service === this) AudioPanel.service = null
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        runCatching {
            stopForeground(STOP_FOREGROUND_REMOVE)
            NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        }
        super.onDestroy()
    }

    /** 快照变了就重画一次面板；进度由 Dart 侧 900ms 节流后推过来。 */
    fun refresh() {
        val mediaSession = session ?: return
        val snapshot = AudioPanel
        mediaSession.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, snapshot.title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, snapshot.artist)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, snapshot.durationMs)
                .build(),
        )
        mediaSession.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(ACTIONS)
                .setState(
                    if (snapshot.playing) {
                        PlaybackStateCompat.STATE_PLAYING
                    } else {
                        PlaybackStateCompat.STATE_PAUSED
                    },
                    snapshot.positionMs.coerceAtLeast(0L),
                    // 暂停时 speed 必须是 0，否则系统会按 1x 外推进度条
                    if (snapshot.playing) 1f else 0f,
                    SystemClock.elapsedRealtime(),
                )
                .setBufferedPosition(snapshot.durationMs.coerceAtLeast(0L))
                .build(),
        )
        try {
            startForegroundCompat()
        } catch (error: Exception) {
            Log.w(TAG, "媒体通知更新失败", error)
        }
    }

    /** 队列清空 / 用户停止：撤掉面板并退出前台。 */
    fun shutdown() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        if (AudioPanel.service === this) AudioPanel.service = null
        runCatching {
            stopForeground(STOP_FOREGROUND_REMOVE)
            NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        }
        stopSelf()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
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

    private fun buildNotification(): Notification {
        val snapshot = AudioPanel
        val playing = snapshot.playing
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_audio)
                .setContentTitle(snapshot.title.ifBlank { "正在播放" })
                .setContentText(snapshot.artist)
                .setContentIntent(launchIntent())
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setSilent(true)
                // 前台服务通知：暂停后也留在通知栏，否则媒体卡消失、无处点继续
                .setOngoing(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
                .addAction(
                    android.R.drawable.ic_media_previous,
                    "上一首",
                    actionIntent(ACTION_PREVIOUS, 1),
                )
                .addAction(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "暂停" else "播放",
                    actionIntent(ACTION_TOGGLE, 2),
                )
                .addAction(
                    android.R.drawable.ic_media_next,
                    "下一首",
                    actionIntent(ACTION_NEXT, 3),
                )
        session?.let {
            builder.setStyle(
                MediaNotificationCompat.MediaStyle()
                    .setMediaSession(it.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
        }
        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel =
            NotificationChannel(CHANNEL_ID, "音频播放", NotificationManager.IMPORTANCE_LOW).apply {
            description = "音乐 / 播客的播放控制"
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    private fun actionIntent(action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            this,
            requestCode,
            Intent(this, AudioPanelService::class.java).setAction(action),
            pendingFlags(),
        )

    /** 点通知 / 锁屏媒体卡回到 App（不清栈、复用已有引擎） */
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
        private const val TAG = "ColaNasAudioPanel"
        private const val CHANNEL_ID = "audio_playback"
        private const val NOTIFICATION_ID = 0x0C02
        private const val ACTION_TOGGLE = "com.colanas.os.audio.TOGGLE"
        private const val ACTION_PREVIOUS = "com.colanas.os.audio.PREVIOUS"
        private const val ACTION_NEXT = "com.colanas.os.audio.NEXT"
        private const val ACTION_STOP = "com.colanas.os.audio.STOP"
        private const val ACTIONS =
            PlaybackStateCompat.ACTION_PLAY or
                PlaybackStateCompat.ACTION_PAUSE or
                PlaybackStateCompat.ACTION_PLAY_PAUSE or
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                PlaybackStateCompat.ACTION_SEEK_TO or
                PlaybackStateCompat.ACTION_STOP
    }
}

/**
 * 面板与 Dart 之间的进程内中转。
 *
 * Dart 每次状态变化推一份快照过来（[update]），面板上的按键回调 [onCommand]，
 * 由 MainActivity 转发回 Flutter 侧。服务没有起来时 [service] 为 null，
 * 此时第一次 [update] 会顺带把服务拉起（这条只在 App 前台发生，符合
 * Android 12+ 对后台启动前台服务的限制）。
 */
object AudioPanel {
    var service: AudioPanelService? = null

    var title: String = ""
    var artist: String = ""
    var playing: Boolean = false
    var positionMs: Long = 0L
    var durationMs: Long = 0L

    var onCommand: ((String, Long) -> Unit)? = null

    fun update(
        context: Context,
        title: String,
        artist: String,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
    ) {
        this.title = title
        this.artist = artist
        this.playing = playing
        this.positionMs = positionMs
        this.durationMs = durationMs
        val running = service
        if (running == null) {
            runCatching {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, AudioPanelService::class.java),
                )
            }.onFailure { Log.w("ColaNasAudioPanel", "拉起媒体服务失败", it) }
        } else {
            running.refresh()
        }
    }

    fun clear(context: Context) {
        service?.shutdown()
    }

    fun dispatch(action: String, positionMs: Long = 0L) {
        onCommand?.invoke(action, positionMs)
    }
}
