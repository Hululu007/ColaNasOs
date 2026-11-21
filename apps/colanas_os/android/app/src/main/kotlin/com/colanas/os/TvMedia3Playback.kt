package com.colanas.os

import android.content.Context
import android.media.MediaCodecList
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

private const val TV_MEDIA3_CHANNEL = "com.colanas.os/tv_media3"
private const val TV_MEDIA3_VIEW_TYPE = "colanasos.tv_media3"

class TvMedia3PlayerFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return TvMedia3PlatformView(context, viewId, messenger)
    }
}

private class TvMedia3PlatformView(
    context: Context,
    private val viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView {
    private val playerView =
        LayoutInflater.from(context).inflate(R.layout.tv_media3_player, null) as PlayerView

    // 必须自己留一份引用：viewId 会被 Flutter 复用，dispose 时不解绑 handler
    // 的话，下一个视图的事件会顺着旧 handler 灌进已经释放的会话。
    private val eventChannel = EventChannel(messenger, "$TV_MEDIA3_CHANNEL/events/$viewId")

    init {
        val session = TvMedia3PlaybackHost.create(context, viewId, playerView)
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    session.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    session.setEventSink(null)
                }
            },
        )
    }

    override fun getView(): View = playerView

    override fun dispose() {
        eventChannel.setStreamHandler(null)
        TvMedia3PlaybackHost.release(viewId)
    }
}

private object TvMedia3PlaybackHost {
    private val sessions = mutableMapOf<Int, TvMedia3Session>()

    fun create(context: Context, viewId: Int, view: PlayerView): TvMedia3Session {
        return sessions.getOrPut(viewId) {
            TvMedia3Session(context.applicationContext, viewId, view)
        }
    }

    fun get(viewId: Int): TvMedia3Session? = sessions[viewId]

    fun release(viewId: Int) {
        sessions.remove(viewId)?.release()
    }
}

private class TvMedia3Session(
    private val context: Context,
    private val viewId: Int,
    private val view: PlayerView,
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
    private val player: ExoPlayer
    private var eventSink: EventChannel.EventSink? = null
    private var videoDecoder = ""
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
        // 解码器回退：某些电视的杜比视界 / HEVC 10bit 硬解实例初始化失败时，
        // 允许 ExoPlayer 继续尝试其它硬件解码器，而不是直接黑屏报错。
        val renderersFactory =
            DefaultRenderersFactory(context)
                .setEnableDecoderFallback(true)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
        player =
            ExoPlayer.Builder(context, renderersFactory)
                .setTrackSelector(trackSelector)
                .setMediaSourceFactory(mediaSourceFactory)
                // 24p 片源在 60Hz 面板上会出现 3:2 抖动；尽量让电视切到匹配刷新率。
                .setVideoChangeFrameRateStrategy(
                    C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS,
                )
                .build()
        player.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        player.setHandleAudioBecomingNoisy(true)
        view.player = player
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
                    // 电视扬声器只能解 PCM / AC3 / EAC3 这类常见音轨；
                    // TrueHD、DTS-HD MA 这类没有平台解码器的音轨如果被选中，
                    // 表现是「有画面没声音」。这里主动报错，让 Dart 侧切到
                    // 服务端转码（视频直通 + 音频转 AAC），而不是让用户对着无声画面。
                    val audioGroups = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
                    if (audioGroups.isNotEmpty() && audioGroups.none { it.isSupported }) {
                        val mime =
                            audioGroups.firstOrNull()
                                ?.takeIf { it.length > 0 }
                                ?.getTrackFormat(0)
                                ?.sampleMimeType
                                ?: "unknown"
                        emitState("no suitable decoder for audio: $mime")
                        return
                    }
                    emitState()
                }

                override fun onPlayerError(error: PlaybackException) {
                    emitState(error.message ?: error.errorCodeName)
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

    fun open(
        url: String,
        positionMs: Long,
        play: Boolean,
        formatHint: String?,
        tunneled: Boolean = false,
        audioUrl: String? = null,
    ) {
        check(!released) { "TV Media3 player has been released" }
        // 手机上开隧道模式会黑屏（解码器就绪但不出帧，VideoSize=0x0）
        trackSelector.setParameters(
            trackSelector.parameters.buildUpon().setTunnelingEnabled(tunneled).build(),
        )
        videoDecoder = ""
        openedAtMs = SystemClock.elapsedRealtime()
        firstFrameMs = null
        player.stop()
        player.clearMediaItems()

        if (!audioUrl.isNullOrBlank()) {
            // 视频与音频分开取：视频走原片（杜比视界配置完整，交给本机 DV 解码器），
            // 音频走服务端转好的 AAC —— 原片的 E-AC3 / DTS-HD 在没有对应解码器的
            // 手机上根本出不了声，而把视频一起转封装又会丢掉 DV 的 dvcC 配置
            // （实测 ffmpeg 8.1 的 mp4 muxer 传不过去），画面直接黑。
            val videoItem =
                MediaItem.Builder()
                    .setUri(url)
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
        view.player = null
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

object TvMedia3MethodHandler : MethodChannel.MethodCallHandler {
    fun install(
        context: Context,
        messenger: BinaryMessenger,
    ) {
        messenger.let {
            MethodChannel(it, TV_MEDIA3_CHANNEL).setMethodCallHandler(this)
        }
        appContext = context.applicationContext
    }

    private var appContext: Context? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("no_context", "Playback context is unavailable", null)
            return
        }
        if (call.method == "supportsDolbyVision") {
            result.success(hasDolbyVisionDecoder())
            return
        }
        val viewId = call.argument<Number>("viewId")?.toInt()
        if (viewId == null) {
            result.error("invalid_view", "viewId is required", null)
            return
        }
        if (call.method == "dispose") {
            TvMedia3PlaybackHost.release(viewId)
            result.success(null)
            return
        }
        val session =
            TvMedia3PlaybackHost.get(viewId)
                ?: run {
                    result.error("missing_player", "Native video view is not ready", null)
                    return
                }
        try {
            if (call.method == "open") {
                val url = call.argument<String>("url")?.trim().orEmpty()
                if (url.isEmpty()) {
                    result.error("invalid_url", "Playback URL is empty", null)
                    return
                }
                session.open(
                    url,
                    call.argument<Number>("positionMs")?.toLong() ?: 0L,
                    call.argument<Boolean>("play") ?: true,
                    call.argument<String>("formatHint"),
                    call.argument<Boolean>("tunneled") ?: false,
                    call.argument<String>("audioUrl"),
                )
            } else {
                session.invoke(call)
            }
            result.success(null)
        } catch (error: Exception) {
            Log.e("TvMedia3", "Native playback command failed: ${call.method}", error)
            result.error("playback_command_failed", error.message, null)
        }
    }

    private fun hasDolbyVisionDecoder(): Boolean {
        return runCatching {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { codec ->
                !codec.isEncoder &&
                    codec.supportedTypes.any { it.equals("video/dolby-vision", ignoreCase = true) }
            }
        }.onFailure {
            Log.w("TvMedia3", "Dolby Vision decoder capability query failed", it)
        }.getOrDefault(false)
    }
}
