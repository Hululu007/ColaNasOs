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
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
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
    context: Context,
    private val viewId: Int,
    private val view: PlayerView,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val trackSelector = DefaultTrackSelector(context)
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
        val mediaSourceFactory =
            DefaultMediaSourceFactory(DefaultDataSource.Factory(context, httpFactory))
        player =
            ExoPlayer.Builder(context)
                .setTrackSelector(trackSelector)
                .setMediaSourceFactory(mediaSourceFactory)
                .build()
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

    fun open(url: String, positionMs: Long, play: Boolean, formatHint: String?) {
        check(!released) { "TV Media3 player has been released" }
        val mediaItem =
            MediaItem.Builder()
                .setUri(url)
                .apply {
                    mimeTypeFor(formatHint)?.let(::setMimeType)
                }
                .build()
        videoDecoder = ""
        openedAtMs = SystemClock.elapsedRealtime()
        firstFrameMs = null
        player.stop()
        player.clearMediaItems()
        player.setMediaItem(mediaItem, positionMs.coerceAtLeast(0L))
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
