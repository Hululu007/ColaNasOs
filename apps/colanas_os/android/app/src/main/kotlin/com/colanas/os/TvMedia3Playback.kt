package com.colanas.os

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.MediaCodecList
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.core.content.ContextCompat
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.session.MediaSession
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

private const val TV_MEDIA3_CHANNEL = "com.colanas.os/tv_media3"
private const val TV_MEDIA3_EVENTS = "$TV_MEDIA3_CHANNEL/events"

/**
 * 全局唯一的视频播放器持有者。
 *
 * 视频同一时刻只会有一路，所以播放器、会话都按单例管理，不再按 Flutter
 * PlatformView 的 viewId 建多份。`VideoMediaSessionService` 也从这里拿到
 * ExoPlayer 来挂 MediaSession。
 */
internal object VideoPlaybackHolder {
    var player: ExoPlayer? = null
    var mediaSession: MediaSession? = null
}

/**
 * 视频原生渲染层：把一个 `PlayerView`（内部是裸 `SurfaceView`）插到 Activity
 * 内容层的最底部（FlutterView 之下），Flutter 用透明像素把它露出来。
 *
 * 这样视频帧由 SurfaceFlinger 直接合成，HDR10 / HDR10+ / HLG / 杜比视界的
 * 元数据不会像纹理通道那样在抓纹理时丢掉；Flutter 的控制条、字幕、手势仍然
 * 画在视频之上。
 */
internal object NativeVideoHost {
    private var appContext: Context? = null
    private var session: TvMedia3Session? = null
    private var playerView: PlayerView? = null
    private var viewOwner: WeakReference<Activity>? = null
    private var eventSink: EventChannel.EventSink? = null

    fun install(activity: Activity, messenger: BinaryMessenger) {
        appContext = activity.applicationContext
        EventChannel(messenger, TV_MEDIA3_EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    session?.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    session?.setEventSink(null)
                }
            },
        )
        MethodChannel(messenger, TV_MEDIA3_CHANNEL).setMethodCallHandler { call, result ->
            handle(activity, call, result)
        }
    }

    private fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        appContext = activity.applicationContext
        try {
            when (call.method) {
                // 能力查询：不需要播放器实例
                "supportsDolbyVision" -> {
                    result.success(hasDolbyVisionDecoder())
                    return
                }
                // 把原生视频层挂到 Flutter 下面 / 从窗口里摘掉
                "attach" -> {
                    attach(activity)
                    result.success(null)
                    return
                }
                "detach" -> {
                    detach()
                    result.success(null)
                    return
                }
                "dispose" -> {
                    dispose()
                    result.success(null)
                    return
                }
            }
            val current = ensureSession(activity.applicationContext)
            when (call.method) {
                "open" -> {
                    val url = call.argument<String>("url")?.trim().orEmpty()
                    if (url.isEmpty()) {
                        result.error("invalid_url", "Playback URL is empty", null)
                        return
                    }
                    current.open(
                        url = url,
                        positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L,
                        play = call.argument<Boolean>("play") ?: true,
                        formatHint = call.argument<String>("formatHint"),
                        tunneled = call.argument<Boolean>("tunneled") ?: false,
                        audioUrl = call.argument<String>("audioUrl"),
                        title = call.argument<String>("title"),
                    )
                    result.success(null)
                }
                else -> {
                    current.invoke(call)
                    result.success(null)
                }
            }
        } catch (error: Exception) {
            Log.e("ColaNasMedia3", "Native playback command failed: ${call.method}", error)
            result.error("playback_command_failed", error.message, null)
        }
    }

    private fun ensureSession(context: Context): TvMedia3Session {
        session?.let { return it }
        val created = TvMedia3Session(context.applicationContext)
        created.setEventSink(eventSink)
        VideoPlaybackHolder.player = created.player
        session = created
        startMediaService(context)
        return created
    }

    private fun attach(activity: Activity) {
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
        // Activity 被重建过：旧 PlayerView 属于旧窗口，直接换一个新的
        var view = playerView
        if (view == null || viewOwner?.get() !== activity) {
            view?.let { (it.parent as? ViewGroup)?.removeView(it) }
            view =
                LayoutInflater.from(activity)
                    .inflate(R.layout.tv_media3_player, content, false) as PlayerView
            playerView = view
            viewOwner = WeakReference(activity)
        }
        if (view.parent == null) {
            // index 0 = 最底层；FlutterView 在它上面，透明像素处露出视频
            content.addView(
                view,
                0,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        ensureSession(activity.applicationContext).attachView(view)
    }

    private fun detach() {
        session?.detachView()
        playerView?.let { (it.parent as? ViewGroup)?.removeView(it) }
    }

    private fun dispose() {
        detach()
        val context = appContext
        // 先摘掉服务能拿到的播放器引用：避免 startService / stopService 的竞态里
        // 服务又用一个即将释放的播放器建出一个新会话。
        VideoPlaybackHolder.player = null
        // 释放顺序：会话 → 服务 → 播放器
        VideoPlaybackHolder.mediaSession?.release()
        VideoPlaybackHolder.mediaSession = null
        context?.let { stopMediaService(it) }
        session?.release()
        session = null
        playerView = null
        viewOwner = null
    }

    private fun startMediaService(context: Context) {
        runCatching {
            // 用 startForegroundService：Android 8+ 在后台直接 startService 会崩，
            // 而播放中的媒体服务本来就该进前台（通知栏媒体卡）。
            ContextCompat.startForegroundService(
                context,
                Intent(context, VideoMediaSessionService::class.java),
            )
        }.onFailure { Log.w("ColaNasMedia3", "媒体服务启动失败", it) }
    }

    private fun stopMediaService(context: Context) {
        runCatching {
            context.stopService(Intent(context, VideoMediaSessionService::class.java))
        }.onFailure { Log.w("ColaNasMedia3", "媒体服务停止失败", it) }
    }

    private fun hasDolbyVisionDecoder(): Boolean {
        return runCatching {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { codec ->
                !codec.isEncoder &&
                    codec.supportedTypes.any { it.equals("video/dolby-vision", ignoreCase = true) }
            }
        }.onFailure {
            Log.w("ColaNasMedia3", "Dolby Vision decoder capability query failed", it)
        }.getOrDefault(false)
    }
}

/** 兼容旧入口名：MainActivity 只调这一个 install。 */
object TvMedia3MethodHandler {
    fun install(
        activity: Activity,
        messenger: BinaryMessenger,
    ) {
        NativeVideoHost.install(activity, messenger)
    }
}

private class TvMedia3Session(
    private val context: Context,
) {
    private val handler = Handler(Looper.getMainLooper())

    // 电视端用隧道模式：音视频同步与合成交给 SoC 的硬件通道，否则 4K / HDR
    // 片源会在应用层多一遍同步与拷贝，表现为持续掉帧。
    //
    // ⚠️ 隧道模式**只有电视芯片认**：手机 / 平板没有 tunneled playback，
    // 打开后解码器能初始化（日志里能看到 c2.qti.dv.decoder 就绪）但一帧都
    // 出不来，VideoSize 停在 0x0，画面纯黑、只有声音。
    // 所以由 Dart 侧按「本机是不是电视」传 `tunneled` 进来，默认关。
    private val trackSelector = DefaultTrackSelector(context)
    private val mediaSourceFactory: DefaultMediaSourceFactory
    val player: ExoPlayer
    private var view: PlayerView? = null
    private var eventSink: EventChannel.EventSink? = null
    private var videoDecoder = ""

    /** 当前轨道里没有任何可用的音频解码器（手机常见：E-AC3 / DTS-HD）。 */
    private var audioUnsupported = false
    private var openedAtMs = 0L
    private var firstFrameMs: Long? = null
    private var released = false

    private val progressTicker =
        object : Runnable {
            override fun run() {
                if (released) return
                emitState()
                handler.postDelayed(this, 250)
            }
        }

    init {
        val httpFactory =
            DefaultHttpDataSource.Factory()
                .setConnectTimeoutMs(30_000)
                .setReadTimeoutMs(60_000)
                .setAllowCrossProtocolRedirects(true)
        mediaSourceFactory =
            DefaultMediaSourceFactory(DefaultDataSource.Factory(context, httpFactory))
        // 解码器回退：某些设备的杜比视界 / HEVC 10bit 硬解实例初始化失败时，
        // 允许 ExoPlayer 继续尝试其它硬件解码器，而不是直接黑屏报错。
        val renderersFactory =
            DefaultRenderersFactory(context)
                .setEnableDecoderFallback(true)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
        player =
            ExoPlayer.Builder(context, renderersFactory)
                .setTrackSelector(trackSelector)
                .setMediaSourceFactory(mediaSourceFactory)
                // 24p 片源在 60Hz 面板上会出现 3:2 抖动；尽量让显示端切到匹配刷新率。
                .setVideoChangeFrameRateStrategy(
                    C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS,
                )
                .build()
        player.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        // handleAudioFocus=true：播放时申请 AUDIOFOCUS_GAIN，音乐 / 播客 / B 站
        // 会被系统暂停 —— 用户要的就是「电影一开就顶掉别的媒体」。
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        player.setHandleAudioBecomingNoisy(true)
        player.addListener(
            object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    emitState()
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    emitState()
                }

                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    emitState()
                }

                override fun onTracksChanged(tracks: Tracks) {
                    // TrueHD / DTS-HD MA 这类音轨没有平台解码器。只记日志不中断：
                    // 画面能出来，Dart 侧会另外接一条 AAC 音频流合并进来。
                    val audioGroups = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
                    audioUnsupported =
                        audioGroups.isNotEmpty() && audioGroups.none { it.isSupported }
                    if (audioUnsupported) {
                        val mime =
                            audioGroups.firstOrNull()
                                ?.takeIf { it.length > 0 }
                                ?.getTrackFormat(0)
                                ?.sampleMimeType
                                ?: "unknown"
                        Log.w(
                            "ColaNasMedia3",
                            "no supported audio decoder ($mime); playing video muted",
                        )
                    }
                    emitState()
                }

                override fun onPlayerError(error: PlaybackException) {
                    val cause = error.cause
                    val detail =
                        buildString {
                            append(error.errorCodeName)
                            append(": ")
                            append(error.message ?: "")
                            if (cause != null) {
                                append(" | ")
                                append(cause.javaClass.simpleName)
                                append(": ")
                                append(cause.message ?: "")
                            }
                        }
                    emitState(detail)
                }
            },
        )
        player.addAnalyticsListener(
            object : AnalyticsListener {
                override fun onVideoDecoderInitialized(
                    eventTime: AnalyticsListener.EventTime,
                    decoderName: String,
                    initializedTimestampMs: Long,
                    initializationDurationMs: Long,
                ) {
                    videoDecoder = decoderName
                    emitState()
                }

                override fun onRenderedFirstFrame(
                    eventTime: AnalyticsListener.EventTime,
                    output: Any,
                    renderTimeMs: Long,
                ) {
                    if (firstFrameMs == null) {
                        firstFrameMs = (SystemClock.elapsedRealtime() - openedAtMs).coerceAtLeast(0L)
                        emitState()
                    }
                }
            },
        )
        handler.post(progressTicker)
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        emitState()
    }

    fun attachView(view: PlayerView) {
        this.view = view
        view.player = player
        emitState()
    }

    fun detachView() {
        view?.player = null
        view = null
    }

    fun open(
        url: String,
        positionMs: Long,
        play: Boolean,
        formatHint: String?,
        tunneled: Boolean = false,
        audioUrl: String? = null,
        title: String? = null,
    ) {
        check(!released) { "Video player has been released" }
        // 手机上开隧道模式会黑屏（解码器就绪但不出帧，VideoSize=0x0）
        trackSelector.setParameters(
            trackSelector.parameters.buildUpon().setTunnelingEnabled(tunneled).build(),
        )
        videoDecoder = ""
        openedAtMs = SystemClock.elapsedRealtime()
        firstFrameMs = null
        player.stop()
        player.clearMediaItems()

        val metadata =
            MediaMetadata.Builder()
                .setTitle(title?.takeIf { it.isNotBlank() } ?: "视频")
                .setMediaType(MediaMetadata.MEDIA_TYPE_MOVIE)
                .build()

        if (!audioUrl.isNullOrBlank()) {
            // 视频与音频分开取：视频走原片（杜比视界配置完整，交给本机 DV 解码器），
            // 音频走服务端转好的 AAC —— 原片的 E-AC3 / DTS-HD 在没有对应解码器的
            // 手机上根本出不了声，而把视频一起转封装又会丢掉 DV 的 dvcC 配置。
            val videoItem =
                MediaItem.Builder()
                    .setUri(url)
                    .setMediaMetadata(metadata)
                    .apply { mimeTypeFor(formatHint)?.let(::setMimeType) }
                    .build()
            val audioItem =
                MediaItem.Builder()
                    .setUri(audioUrl)
                    .setMimeType(MimeTypes.APPLICATION_M3U8)
                    .build()
            player.setMediaSource(
                MergingMediaSource(
                    mediaSourceFactory.createMediaSource(videoItem),
                    mediaSourceFactory.createMediaSource(audioItem),
                ),
                positionMs.coerceAtLeast(0L),
            )
        } else {
            val mediaItem =
                MediaItem.Builder()
                    .setUri(url)
                    .setMediaMetadata(metadata)
                    .apply {
                        mimeTypeFor(formatHint)?.let(::setMimeType)
                    }
                    .build()
            player.setMediaItem(mediaItem, positionMs.coerceAtLeast(0L))
        }
        player.playWhenReady = play
        player.prepare()
        emitState()
    }

    fun selectAudioTrack(index: Int) {
        var current = 0
        for (group in player.currentTracks.groups) {
            if (group.type != C.TRACK_TYPE_AUDIO) continue
            for (trackIndex in 0 until group.length) {
                if (current++ != index) continue
                trackSelector.setParameters(
                    trackSelector.parameters
                        .buildUpon()
                        .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                        .setOverrideForType(
                            androidx.media3.common.TrackSelectionOverride(
                                group.mediaTrackGroup,
                                trackIndex,
                            ),
                        )
                        .build(),
                )
                return
            }
        }
    }

    fun invoke(call: MethodCall) {
        when (call.method) {
            "play" -> player.play()
            "pause" -> player.pause()
            "seekTo" -> player.seekTo(call.argument<Number>("positionMs")?.toLong() ?: 0L)
            "setVolume" -> {
                player.volume =
                    (call.argument<Number>("volume")?.toFloat() ?: 1f).coerceIn(0f, 1f)
            }
            "setRate" -> {
                val rate = (call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(0.5f, 2f)
                player.playbackParameters =
                    androidx.media3.common.PlaybackParameters(rate)
            }
            "setAudioTrack" -> {
                selectAudioTrack(call.argument<Number>("index")?.toInt() ?: 0)
            }
            "setRepeatMode" -> {
                player.repeatMode =
                    when (call.argument<String>("mode")) {
                        "one" -> Player.REPEAT_MODE_ONE
                        "all" -> Player.REPEAT_MODE_ALL
                        else -> Player.REPEAT_MODE_OFF
                    }
            }
            "setShuffle" -> {
                player.shuffleModeEnabled = call.argument<Boolean>("enabled") ?: false
            }
            "stop" -> {
                player.stop()
                player.clearMediaItems()
                emitState()
            }
        }
    }

    fun release() {
        if (released) return
        released = true
        handler.removeCallbacks(progressTicker)
        view?.player = null
        view = null
        player.release()
        eventSink = null
    }

    private fun emitState(error: String? = null) {
        val sink = eventSink ?: return
        val size = player.videoSize
        val duration = player.duration.takeIf { it != C.TIME_UNSET }?.coerceAtLeast(0L) ?: 0L
        sink.success(
            mapOf(
                "positionMs" to player.currentPosition.coerceAtLeast(0L),
                "durationMs" to duration,
                "bufferedPositionMs" to player.bufferedPosition.coerceAtLeast(0L),
                "videoWidth" to size.width,
                "videoHeight" to size.height,
                "isPlaying" to player.isPlaying,
                "isBuffering" to (player.playbackState == Player.STATE_BUFFERING),
                "isCompleted" to (player.playbackState == Player.STATE_ENDED),
                "videoDecoder" to videoDecoder,
                "firstFrameMs" to firstFrameMs,
                // 音频没有解码器：让 Dart 侧去建「视频原片 + 音频 AAC」的合并会话
                "audioUnsupported" to audioUnsupported,
                "viewWidth" to (view?.width ?: 0),
                "viewHeight" to (view?.height ?: 0),
                "surfaceWidth" to (view?.videoSurfaceView?.width ?: 0),
                "surfaceHeight" to (view?.videoSurfaceView?.height ?: 0),
                if (error != null) "error" to error else "error" to null,
            ),
        )
    }

    private fun mimeTypeFor(formatHint: String?): String? =
        when (formatHint?.trim()?.lowercase()) {
            "hls", "m3u8" -> MimeTypes.APPLICATION_M3U8
            "mkv", "matroska" -> MimeTypes.VIDEO_MATROSKA
            "mp4", "m4v", "mov" -> MimeTypes.VIDEO_MP4
            "webm" -> MimeTypes.VIDEO_WEBM
            "ts", "m2ts", "mts", "mpegts" -> MimeTypes.VIDEO_MP2T
            else -> null
        }
}
