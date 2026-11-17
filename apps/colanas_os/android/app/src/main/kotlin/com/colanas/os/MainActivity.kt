package com.colanas.os

import android.content.pm.PackageManager
import android.os.Build
import android.view.Display
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 必须继承 AudioServiceActivity（而不是 FlutterActivity）：
// audio_service 的前台服务把通知栏 / 锁屏的点击回传给 Activity，
// 用这个基类才能回到同一个 Flutter 引擎，而不是重启一个。
class MainActivity : AudioServiceActivity() {

    companion object {
        private const val BACKUP_CHANNEL = "com.colanas.os/photo_backup"
        private const val DISPLAY_CHANNEL = "com.colanas.os/display_caps"
        private const val DOWNLOAD_CHANNEL = "com.colanas.os/offline_download"
        private const val REQ_NOTIFICATIONS = 1001
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "相册备份"
                        val text = call.argument<String>("text") ?: ""
                        val channelName = call.argument<String>("channelName") ?: "相册备份"
                        result.success(runCatching {
                            BackupForegroundService.start(this, title, text, channelName)
                        }.isSuccess)
                    }
                    "update" -> {
                        val title = call.argument<String>("title") ?: "相册备份"
                        val text = call.argument<String>("text") ?: ""
                        val progress = call.argument<Int>("progress") ?: -1
                        val max = call.argument<Int>("max") ?: 100
                        result.success(runCatching {
                            BackupForegroundService.update(this, title, text, progress, max)
                        }.isSuccess)
                    }
                    "stop" -> {
                        result.success(runCatching {
                            BackupForegroundService.stop(this)
                        }.isSuccess)
                    }
                    // Android 13+ 不申请 POST_NOTIFICATIONS，前台服务跑着但通知栏看不到。
                    "ensureNotificationPermission" -> ensureNotificationPermission(result)
                    else -> result.notImplemented()
                }
            }

        // 离线下载的前台服务：下载开始 / 进度 / 结束三件事。
        // 失败一律返回 false，不抛给 Dart —— 没有通知栏也得能下载。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "正在下载"
                        val text = call.argument<String>("text") ?: ""
                        result.success(runCatching {
                            DownloadForegroundService.start(this, title, text)
                        }.isSuccess)
                    }
                    "update" -> {
                        val text = call.argument<String>("text") ?: ""
                        val progress = call.argument<Int>("progress") ?: -1
                        val max = call.argument<Int>("max") ?: 100
                        result.success(runCatching {
                            DownloadForegroundService.update(this, text, progress, max)
                        }.isSuccess)
                    }
                    "stop" -> result.success(runCatching {
                        DownloadForegroundService.stop(this)
                    }.isSuccess)
                    "ensureNotificationPermission" -> ensureNotificationPermission(result)
                    else -> result.notImplemented()
                }
            }

        // 电视 HDR 能力：播放器按它决定「直连原画」还是「服务端色调映射转码」。
        // 只读能力，不改任何播放状态；老系统 / 通道异常时返回空数组，
        // Dart 侧按「能力未知」处理（不退化成「不支持」）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hdrTypes" -> result.success(readHdrTypes())
                    else -> result.notImplemented()
                }
            }
    }

    /// `Display.HdrCapabilities` 的四种类型：
    /// 1 = Dolby Vision，2 = HDR10，3 = HLG，4 = HDR10+（与 Dart 侧 HdrLevel 对齐）。
    private fun readHdrTypes(): List<Int> {
        return runCatching {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return@runCatching emptyList<Int>()
            val display: Display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display ?: windowManager.defaultDisplay
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            }
            val caps = display.hdrCapabilities ?: return@runCatching emptyList<Int>()
            caps.supportedHdrTypes?.toList() ?: emptyList()
        }.getOrDefault(emptyList())
    }

    private fun notificationGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun ensureNotificationPermission(result: MethodChannel.Result) {
        if (notificationGranted()) {
            result.success(true)
            return
        }
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        requestPermissions(
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIFICATIONS,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }
}
