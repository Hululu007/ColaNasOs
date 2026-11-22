package com.colanas.os

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.View
import android.view.ViewGroup
import androidx.core.content.FileProvider
import java.io.File
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 必须继承 AudioService*（而不是 FlutterActivity）：
// audio_service 的前台服务把通知栏 / 锁屏的点击回传给 Activity，
// 用这个基类才能回到同一个 Flutter 引擎，而不是重启一个。
//
// 渲染模式用默认的 `surface` + **不透明窗口**：视频画面走 PlatformView
// （Hybrid Composition）嵌在 Flutter 视图树里，是窗口内的一块真实 Surface。
// 不透明窗口里这一层才能拿到独占的 HDR 合成通道 —— 一旦整窗透明
// （`windowIsTranslucent` + texture 渲染），杜比视界会被当 SDR 混合，画面发紫。
class MainActivity : AudioServiceActivity() {

    companion object {
        private const val BACKUP_CHANNEL = "com.colanas.os/photo_backup"
        private const val DISPLAY_CHANNEL = "com.colanas.os/display_caps"
        private const val DOWNLOAD_CHANNEL = "com.colanas.os/offline_download"
        private const val UPDATE_CHANNEL = "com.colanas.os/update"
        private const val DV_PROBE_CHANNEL = "com.colanas.os/dv_probe"
        private const val REQ_NOTIFICATIONS = 1001
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // 视频画面：PlatformView（Hybrid Composition，窗口内真实 Surface）。
        // 控制命令 + 状态事件走 MethodChannel / EventChannel。
        flutterEngine.platformViewsController.registry.registerViewFactory(
            TvVideoViewFactory.VIEW_TYPE,
            TvVideoViewFactory(this),
        )
        TvMedia3MethodHandler.install(this, messenger)
        MethodChannel(messenger, BACKUP_CHANNEL)
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
        MethodChannel(messenger, DOWNLOAD_CHANNEL)
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

        /**
         * 客户端自更新：把下载好的 APK 交给**系统安装器**。
         *
         * 安卓不给普通应用静默安装的权限（那需要系统签名或设备管理器），
         * 所以这里能做的最多是：校验签名一致 → 申请「安装未知应用」→ 起 Intent。
         * 任何一步失败都返回明确错误码，Dart 侧据此给「去授权 / 复制链接」的兜底。
         */
        MethodChannel(messenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val filePath = call.argument<String>("path")
                        if (filePath.isNullOrEmpty()) {
                            result.error("E_ARGS", "缺少安装包路径", null)
                            return@setMethodCallHandler
                        }
                        installApk(File(filePath), result)
                    }
                    "canInstall" -> result.success(canInstallUnknownApps())
                    else -> result.notImplemented()
                }
            }

        // 电视 HDR 能力：播放器按它决定「直连原画」还是「服务端色调映射转码」。
        // 只读能力，不改任何播放状态；老系统 / 通道异常时返回空数组，
        // Dart 侧按「能力未知」处理（不退化成「不支持」）。
        MethodChannel(messenger, DISPLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hdrTypes" -> result.success(readHdrTypes())
                    else -> result.notImplemented()
                }
            }

        // P0.5 临时探针：debug / profile 包里用「播放信息」面板标题长按唤起，
        // 不走 Flutter 平台视图，直接验证原生 SurfaceView 的真实 DV 输出。
        // 正式版没有入口；方案 A 定稿或否掉后连同 DvProbeActivity 一起删除。
        MethodChannel(messenger, DV_PROBE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launch" -> {
                        val url = call.argument<String>("url")?.trim()
                        if (url.isNullOrEmpty()) {
                            result.error("E_ARGS", "缺少播放地址", null)
                            return@setMethodCallHandler
                        }
                        runCatching {
                            startActivity(
                                Intent(this, DvProbeActivity::class.java).apply {
                                    putExtra(DvProbeActivity.EXTRA_URL, url)
                                    call.argument<String>("audioUrl")?.let {
                                        putExtra(DvProbeActivity.EXTRA_AUDIO_URL, it)
                                    }
                                    call.argument<String>("formatHint")?.let {
                                        putExtra(DvProbeActivity.EXTRA_FORMAT_HINT, it)
                                    }
                                },
                            )
                        }.fold(
                            onSuccess = { result.success(true) },
                            onFailure = { result.error("E_INTENT", it.message, null) },
                        )
                    }
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

    /** 新包签名必须与当前应用一致，否则就是被换了包的钓鱼更新 */
    @Suppress("DEPRECATION")
    private fun sameSigner(file: File): Boolean {
        // API 28 以下没有 SigningInfo（getPackageArchiveInfo 也拿不到），
        // 硬比会直接抛 NoSuchMethodError；这些老系统交给系统安装器自己校验
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return true
        return runCatching {
            val flags = PackageManager.GET_SIGNING_CERTIFICATES
            val info = packageManager.getPackageArchiveInfo(file.absolutePath, flags) ?: return false
            val incoming = info.signingInfo?.apkContentsSigners ?: return false
            val mine = packageManager.getPackageInfo(packageName, flags).signingInfo?.apkContentsSigners
                ?: return false
            incoming.any { a -> mine.any { b -> a.toCharsString() == b.toCharsString() } }
        }.getOrDefault(false)
    }

    private fun canInstallUnknownApps(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun installApk(file: File, result: MethodChannel.Result) {
        if (!file.exists() || file.length() <= 0L) {
            result.error("E_NO_FILE", "安装包不存在", null)
            return
        }
        if (!sameSigner(file)) {
            // 签名不一致：宁可报错也不让用户装上假包
            result.error("E_SIGNATURE", "安装包签名与应用不一致，已拒绝安装", null)
            return
        }
        if (!canInstallUnknownApps()) {
            // 引导到「安装未知应用」授权页；用户回来再点更新即可
            runCatching {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                )
            }
            result.error("E_PERMISSION", "请先允许本应用安装未知应用", null)
            return
        }
        runCatching {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        }.fold(
            onSuccess = { result.success(true) },
            onFailure = { result.error("E_INTENT", "拉起系统安装器失败: ${it.message}", null) },
        )
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
