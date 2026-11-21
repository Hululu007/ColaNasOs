import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_install_base.dart';
import 'update_service.dart';

UpdateInstaller createUpdateInstaller() => IoUpdateInstaller();

/// 桌面 / 安卓的更新安装器。
///
/// 下载器刻意自己写而不是用 `http.get`：
///   - 要进度（服务端 45 MB 的 APK 在大屏上是 1 分钟的事，没进度条等于「卡死」）；
///   - 要续传（`.part` + Range），弱网/切后台中断后不必从头再来；
///   - 要多源熔断（局域网 → GitCode → GitHub），一个源挂了自动换。
class IoUpdateInstaller implements UpdateInstaller {
  static const MethodChannel _channel = MethodChannel('com.colanas.os/update');

  http.Client? _client;
  bool _cancelled = false;

  @override
  void cancel() {
    _cancelled = true;
    _client?.close();
    _client = null;
  }

  Future<Directory> _downloadDir() async {
    if (Platform.isAndroid) {
      // getTemporaryDirectory 在安卓上是应用私有 cache，卸载即清，符合预期
      return getTemporaryDirectory();
    }
    final dir = await getTemporaryDirectory();
    return dir;
  }

  @override
  Future<String> download({
    required UpdateAsset asset,
    required void Function(int loaded, int total, int speed) onProgress,
    required void Function() onVerify,
  }) async {
    _cancelled = false;
    final dir = await _downloadDir();
    // 扩展名要跟资产类型走：便携版是 zip，套上 .exe 会被当成安装程序直接启动
    final ext = _extFor(asset);
    final name = 'colanas-update-${asset.kind}-${asset.sha256.substring(0, 8)}$ext';
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    final part = File('${target.path}.part');

    // 完整文件还在且校验通过：直接复用（用户上次装了但没成功的情况）
    if (await target.exists() && asset.sha256.isNotEmpty) {
      if (await _hashOf(target) == asset.sha256) {
        onVerify();
        return target.path;
      }
      await target.delete();
    }

    Object? lastError;
    for (final url in asset.urls) {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (_cancelled) throw const _Cancelled();
        try {
          await _fetch(url, part, asset, onProgress);
          onVerify();
          final digest = await _hashOf(part);
          if (asset.sha256.isNotEmpty && digest != asset.sha256) {
            // 内容错了就别续传了：删掉重来（换源）
            await part.delete();
            throw StateError('digest mismatch');
          }
          if (await target.exists()) await target.delete();
          await part.rename(target.path);
          return target.path;
        } catch (e) {
          lastError = e;
          if (_cancelled) throw const _Cancelled();
          // 保留 .part 续传；只有摘要不符才会在上面删掉
        }
      }
    }
    throw StateError('所有下载源都失败：$lastError');
  }

  Future<void> _fetch(
    String url,
    File part,
    UpdateAsset asset,
    void Function(int, int, int) onProgress,
  ) async {
    var offset = 0;
    if (await part.exists()) {
      offset = await part.length();
    }
    final client = http.Client();
    _client = client;
    try {
      final req = http.Request('GET', Uri.parse(url));
      if (offset > 0) req.headers['range'] = 'bytes=$offset-';
      final res = await client.send(req);
      if (res.statusCode == 416) {
        await part.delete();
        offset = 0;
        throw StateError('range invalid');
      }
      if (res.statusCode >= 400) {
        await res.stream.drain<void>();
        throw StateError('HTTP ${res.statusCode}');
      }
      final ranged = res.statusCode == 206;
      if (offset > 0 && !ranged) {
        await part.writeAsBytes(const <int>[], flush: true);
        offset = 0;
      }
      final total = asset.size > 0 ? asset.size : offset + (res.contentLength ?? 0);

      final sink = part.openWrite(
        mode: offset > 0 && ranged ? FileMode.append : FileMode.write,
      );
      var loaded = offset;
      var windowStart = DateTime.now();
      var windowBytes = 0;
      var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        await for (final chunk in res.stream) {
          if (_cancelled) throw const _Cancelled();
          sink.add(chunk);
          loaded += chunk.length;
          windowBytes += chunk.length;
          final now = DateTime.now();
          final elapsed = now.difference(windowStart).inMilliseconds;
          if (elapsed >= 500) {
            final speed = (windowBytes * 1000 / elapsed).round();
            windowStart = now;
            windowBytes = 0;
            if (now.difference(lastEmit).inMilliseconds >= 120) {
              lastEmit = now;
              onProgress(loaded, total, speed);
            }
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      onProgress(loaded, total, 0);
      if (total > 0 && loaded < total) {
        throw StateError('truncated $loaded/$total');
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  /// 安装包的扩展名：优先取清单 URL 上的真实后缀
  String _extFor(UpdateAsset asset) {
    for (final url in asset.urls) {
      final path = Uri.tryParse(url)?.path ?? '';
      final dot = path.lastIndexOf('.');
      if (dot > 0 && path.length - dot <= 6) return path.substring(dot).toLowerCase();
    }
    if (Platform.isWindows) return '.exe';
    if (Platform.isAndroid) return '.apk';
    return '.bin';
  }

  Future<String> _hashOf(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  @override
  Future<void> install({required String path, required UpdateAsset asset}) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('installApk', {'path': path});
      return;
    }
    if (Platform.isWindows) {
      if (!path.toLowerCase().endsWith('.exe')) {
        throw UnsupportedError('这个平台只支持安装版自动更新，请手动下载更新包');
      }
      // 静默安装：`/S` 不弹界面；`COLANAS_RELAUNCH=1` 让 NSIS 装完自动把新客户端拉起来
      // （安装器的 Section 末尾读这个变量，见 tool/build-client-installer.js）
      await Process.start(
        path,
        const ['/S'],
        environment: {'COLANAS_RELAUNCH': '1'},
        mode: ProcessStartMode.detached,
      );
      // 让安装器拿到 exe 句柄：它内部的 STOP_RUNNING_APP 会再兜底一次
      exit(0);
    }
    if (Platform.isMacOS || Platform.isLinux) {
      throw UnsupportedError('当前平台不支持自动安装，请手动下载更新包');
    }
    throw UnsupportedError('unsupported platform');
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => '已取消';
}
