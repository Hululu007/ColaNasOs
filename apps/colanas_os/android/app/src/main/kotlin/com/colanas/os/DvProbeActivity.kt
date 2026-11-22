package com.colanas.os

import android.app.Activity
import android.graphics.Color
import android.media.MediaCodecList
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
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

/**
 * 临时探针（P0.5）：验证「原生 SurfaceView 直接挂在 Activity 上」能否在手机上
 * 真正输出杜比视界 / HDR，并同时确认 Flutter 控件层（窗口层 View）能盖在视频之上。
 *
 * 它**不接业务**、不走 Flutter 平台视图，只在 debug / profile 包里通过播放信息
 * 面板标题长按唤起。验证完（方案 A 定稿或否掉）整个文件与 Manifest 条目一起删除。
 *
 * 结论看两处：
 * 1. 屏幕左上角状态条：decoder / size / view / surface / firstFrame；
 * 2. logcat：`adb logcat -s DvProbe`。
 */
class DvProbeActivity : Activity() {
    companion object {
        private const val TAG = "DvProbe"
        const val EXTRA_URL = "url"
        const val EXTRA_AUDIO_URL = "audioUrl"
        const val EXTRA_FORMAT_HINT = "formatHint"
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var playerView: PlayerView
    private lateinit var status: TextView
    private lateinit var player: ExoPlayer
    private var decoder = ""
    private var firstFrameMs: Long? = null
    private var openedAt = 0L
    private var lastError: String? = null
    private var overlayVisible = true

    private val ticker =
        object : Runnable {
            override fun run() {
                renderStatus()
                handler.postDelayed(this, 500)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)?.trim().orEmpty()
        if (url.isEmpty()) {
            Log.e(TAG, "missing url extra")
            finish()
            return
        }
        val audioUrl = intent.getStringExtra(EXTRA_AUDIO_URL)?.trim().orEmpty()
        val formatHint = intent.getStringExtra(EXTRA_FORMAT_HINT)

        val root = FrameLayout(this)
        playerView =
            PlayerView(this).apply {
                layoutParams =
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                useController = false
                setShowBuffering(PlayerView.SHOW_BUFFERING_ALWAYS)
                keepScreenOn = true
                setShutterBackgroundColor(Color.BLACK)
            }
        root.addView(playerView)

        // 控件层：普通窗口层 View，和 Flutter texture 渲染处在同一层。
        // 半透明底 + 按钮，用来确认「控件确实盖在视频之上」。
        val overlay =
            FrameLayout(this).apply {
                layoutParams =
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
            }
        status =
            TextView(this).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setBackgroundColor(0xB3000000.toInt())
                setPadding(24, 24, 24, 24)
                layoutParams =
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        Gravity.TOP,
                    )
            }
        overlay.addView(status)

        val row =
            LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setBackgroundColor(0x80000000.toInt())
                setPadding(16, 8, 16, 8)
                layoutParams =
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        Gravity.BOTTOM,
                    )
            }
        row.addView(
            button("播放/暂停") {
                if (player.isPlaying) player.pause() else player.play()
            },
        )
        row.addView(
            button("隐藏控件") {
                overlayVisible = !overlayVisible
                overlay.visibility = if (overlayVisible) View.VISIBLE else View.GONE
            },
        )
        row.addView(button("退出") { finish() })
        overlay.addView(row)
        root.addView(overlay)

        setContentView(root)
        buildPlayer(url, audioUrl, formatHint)
        handler.post(ticker)
    }

    private fun button(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 12f
            setOnClickListener { onClick() }
        }

    private fun buildPlayer(url: String, audioUrl: String, formatHint: String?) {
        val httpFactory =
            DefaultHttpDataSource.Factory()
                .setConnectTimeoutMs(30_000)
                .setReadTimeoutMs(60_000)
                .setAllowCrossProtocolRedirects(true)
        val sourceFactory = DefaultMediaSourceFactory(DefaultDataSource.Factory(this, httpFactory))
        val renderers =
            DefaultRenderersFactory(this)
                .setEnableDecoderFallback(true)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
        val trackSelector = DefaultTrackSelector(this)
        trackSelector.setParameters(
            trackSelector.parameters.buildUpon().setTunnelingEnabled(false).build(),
        )
        player =
            ExoPlayer.Builder(this, renderers)
                .setTrackSelector(trackSelector)
                .setMediaSourceFactory(sourceFactory)
                .build()
        player.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        playerView.player = player
        player.addListener(
            object : Player.Listener {
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    log("videoSize=${videoSize.width}x${videoSize.height}")
                }

                override fun onPlayerError(error: PlaybackException) {
                    lastError =
                        buildString {
                            append(error.errorCodeName)
                            append(": ")
                            append(error.message ?: "")
                            error.cause?.let {
                                append(" | ")
                                append(it.javaClass.simpleName)
                                append(": ")
                                append(it.message ?: "")
                            }
                        }
                    Log.e(TAG, "playerError=$lastError")
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
                    decoder = decoderName
                    log("decoder=$decoderName init=${initializationDurationMs}ms")
                }

                override fun onRenderedFirstFrame(
                    eventTime: AnalyticsListener.EventTime,
                    output: Any,
                    renderTimeMs: Long,
                ) {
                    if (firstFrameMs == null) {
                        firstFrameMs = (SystemClock.elapsedRealtime() - openedAt).coerceAtLeast(0L)
                        log("firstFrame=${firstFrameMs}ms")
                    }
                }
            },
        )

        val videoItem =
            MediaItem.Builder()
                .setUri(url)
                .apply { mimeTypeFor(formatHint)?.let(::setMimeType) }
                .build()
        if (audioUrl.isNotEmpty()) {
            val audioItem =
                MediaItem.Builder()
                    .setUri(audioUrl)
                    .setMimeType(MimeTypes.APPLICATION_M3U8)
                    .build()
            player.setMediaSource(
                MergingMediaSource(
                    sourceFactory.createMediaSource(videoItem),
                    sourceFactory.createMediaSource(audioItem),
                ),
            )
        } else {
            player.setMediaItem(videoItem)
        }
        openedAt = SystemClock.elapsedRealtime()
        player.playWhenReady = true
        player.prepare()
        log(
            "open url=$url audio=${audioUrl.ifEmpty { "-" }} " +
                "dvDecoder=${hasDolbyVisionDecoder()} displayHdr=${readHdrTypes()}",
        )
    }

    private fun renderStatus() {
        if (!::status.isInitialized) return
        val size = player.videoSize
        val surface = playerView.videoSurfaceView
        status.text =
            buildString {
                append("decoder=").append(decoder.ifEmpty { "-" })
                append("  size=").append(size.width).append("x").append(size.height)
                append("\nview=").append(playerView.width).append("x").append(playerView.height)
                append("  surface=").append(surface?.width ?: 0).append("x")
                append(surface?.height ?: 0)
                append("  first=").append(firstFrameMs?.let { "${it}ms" } ?: "-")
                append("\nstate=").append(stateName(player.playbackState))
                append("  pos=").append(player.currentPosition)
                append("  playing=").append(player.isPlaying)
                lastError?.let { append("\nERROR=").append(it) }
            }
    }

    private fun stateName(state: Int): String =
        when (state) {
            Player.STATE_IDLE -> "IDLE"
            Player.STATE_BUFFERING -> "BUFFERING"
            Player.STATE_READY -> "READY"
            Player.STATE_ENDED -> "ENDED"
            else -> state.toString()
        }

    private fun log(message: String) {
        Log.i(TAG, message)
    }

    private fun readHdrTypes(): List<Int> =
        runCatching {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                return@runCatching emptyList<Int>()
            }
            @Suppress("DEPRECATION")
            val display: Display = windowManager.defaultDisplay
            display.hdrCapabilities?.supportedHdrTypes?.toList() ?: emptyList()
        }.getOrDefault(emptyList())

    private fun hasDolbyVisionDecoder(): Boolean =
        runCatching {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { codec ->
                !codec.isEncoder &&
                    codec.supportedTypes.any { it.equals("video/dolby-vision", ignoreCase = true) }
            }
        }.getOrDefault(false)

    private fun mimeTypeFor(formatHint: String?): String? =
        when (formatHint?.trim()?.lowercase()) {
            "hls", "m3u8" -> MimeTypes.APPLICATION_M3U8
            "mkv", "matroska" -> MimeTypes.VIDEO_MATROSKA
            "mp4", "m4v", "mov" -> MimeTypes.VIDEO_MP4
            "webm" -> MimeTypes.VIDEO_WEBM
            "ts", "m2ts", "mts", "mpegts" -> MimeTypes.VIDEO_MP2T
            else -> null
        }

    override fun onPause() {
        player.pause()
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacks(ticker)
        if (::player.isInitialized) {
            playerView.player = null
            player.release()
        }
        super.onDestroy()
    }
}
