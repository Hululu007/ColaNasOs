import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// HTTP Range 下载 + SHA-256 校验。
///
/// 两种模式：
///   * **单连接**（默认兜底）：支持断点续传，边下边算哈希；
///   * **分片并发**（`connections > 1`，只在从零开始且文件 > 8MB 时启用）：
///     单连接在 WiFi 中继 / 反向代理 / 单流限速的链路上跑不满带宽，切成几段并发
///     能明显提速。分片模式放弃了断点续传（段文件对不齐就没法续），
///     中断后下次从零开始。
class OfflineTransfer {
  OfflineTransfer._();

  /// 小于这个尺寸不值得分片：握手开销比省下的时间还多。
  static const int _parallelMinBytes = 8 * 1024 * 1024;

  /// 把 `uri` 的内容写进 [target]（`.part` 临时文件）。
  ///
  /// - [resumeFrom] > 0 时先给已有前缀算一遍哈希，再带 `Range` + `If-Range` 续传；
  /// - 服务端回 200（说明产物变了 / 不认 Range）就丢弃已有字节从头下；
  /// - [connections] > 1 且是新下载、文件够大时走分片并发（见 [_downloadParallel]）；
  /// - [onProgress] 每次有进展回调一次（调用方自己去抖）。
  static Future<TransferOutcome> download({
    required Uri uri,
    required Map<String, String> headers,
    required File target,
    required String etag,
    required int expectedBytes,
    int resumeFrom = 0,
    /// 限速（字节/秒）；0 = 不限。只压下载这一段，不影响服务端转码。
    int maxBytesPerSecond = 0,
    /// 分片连接数（1 = 单连接）。只在「从零开始 + 文件够大」时生效。
    int connections = 1,
    bool Function()? isCanceled,
    void Function(int received)? onProgress,
  }) async {
    final n = connections.clamp(1, 8);
    final useParallel = n > 1 && resumeFrom == 0 && expectedBytes > _parallelMinBytes;
    if (useParallel) {
      try {
        return await _downloadParallel(
          uri: uri,
          headers: headers,
          target: target,
          etag: etag,
          expectedBytes: expectedBytes,
          connections: n,
          maxBytesPerSecond: maxBytesPerSecond,
          isCanceled: isCanceled,
          onProgress: onProgress,
        );
      } on TransferCanceled {
        rethrow;
      } catch (_) {
        // 分片失败（服务端不认 Range / 某条连接被掐）：清干净退回单连接。
        // 用户要的是「下得完」，不是「必须多连接」。
        await _quietDelete(target);
      }
    }
    return _downloadSingle(
      uri: uri,
      headers: headers,
      target: target,
      etag: etag,
      expectedBytes: expectedBytes,
      resumeFrom: resumeFrom,
      maxBytesPerSecond: maxBytesPerSecond,
      isCanceled: isCanceled,
      onProgress: onProgress,
    );
  }

  static Future<void> _quietDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉不影响后续流程
    }
  }

  /// 单连接下载（也是分片失败后的兜底）。
  static Future<TransferOutcome> _downloadSingle({
    required Uri uri,
    required Map<String, String> headers,
    required File target,
    required String etag,
    required int expectedBytes,
    int resumeFrom = 0,
    int maxBytesPerSecond = 0,
    bool Function()? isCanceled,
    void Function(int received)? onProgress,
  }) async {
    final client = http.Client();
    IOSink? sink;
    try {
      await target.parent.create(recursive: true);

      var offset = resumeFrom;
      final hasher = _StreamingSha256();
      if (offset > 0) {
        if (!await target.exists() || await target.length() < offset) {
          offset = 0;
        } else {
          // 续传前先把已有前缀喂进哈希，否则最终 sha256 只有后半段
          await for (final chunk in target.openRead()) {
            hasher.add(chunk);
            if (isCanceled?.call() == true) {
              throw const TransferCanceled();
            }
          }
        }
      }

      final request = http.Request('GET', uri);
      request.headers.addAll(headers);
      if (offset > 0) {
        request.headers['range'] = 'bytes=$offset-';
        if (etag.isNotEmpty) request.headers['if-range'] = etag;
      }

      final response = await client.send(request);
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw TransferFailed('HTTP ${response.statusCode}');
      }

      var startAt = offset;
      if (response.statusCode == 200) {
        // 服务端不认 Range（产物变了）：重头来
        startAt = 0;
        offset = 0;
        if (await target.exists()) await target.delete();
        hasher.reset();
      }

      sink = target.openWrite(mode: startAt > 0 ? FileMode.append : FileMode.write);
      var received = startAt;
      // 限速按「本次实际下载的字节」记账：续传时已存在的那部分不该算进配额
      final clock = Stopwatch()..start();

      await for (final chunk in response.stream) {
        if (isCanceled?.call() == true) {
          throw const TransferCanceled();
        }
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received);

        if (maxBytesPerSecond > 0) {
          // 落后于配额就睡一会儿。睡够 1s 封顶：网络本身有抖动，
          // 用「总额补偿」比「每块固定 sleep」稳得多，也不会把一帧卡成几秒。
          final downloaded = received - startAt;
          final expectedMs = downloaded / maxBytesPerSecond * 1000;
          final ahead = expectedMs - clock.elapsedMilliseconds;
          if (ahead > 0) {
            await Future<void>.delayed(
              Duration(milliseconds: ahead.clamp(0, 1000).round()),
            );
          }
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final actual = await target.length();
      if (expectedBytes > 0 && actual != expectedBytes) {
        throw TransferFailed('传入字节数对不上：$actual / $expectedBytes');
      }
      return TransferOutcome(bytes: actual, sha256: hasher.finish());
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 写盘失败时 close 也会抛，忽略即可（错误已由上面的 catch 上报）
      }
      client.close();
    }
  }

  /// 分片并发下载：文件切成 [connections] 段，各段独立拉、各自落一个临时文件，
  /// 到齐后按顺序拼成 [target]，拼接时顺手算 SHA-256。
  ///
  /// 为什么用段文件而不是「同一个句柄按偏移写」：Dart 的 `File.open` 写模式会截断，
  /// 多个句柄打开同一路径会互相清空；`FileMode.append` 又固定写到末尾，偏移无效。
  /// 段文件 + 拼接是唯一稳的做法，代价是峰值多占一份磁盘（拼完立刻删）。
  static Future<TransferOutcome> _downloadParallel({
    required Uri uri,
    required Map<String, String> headers,
    required File target,
    required String etag,
    required int expectedBytes,
    required int connections,
    required int maxBytesPerSecond,
    bool Function()? isCanceled,
    void Function(int received)? onProgress,
  }) async {
    await target.parent.create(recursive: true);
    await _quietDelete(target);

    final n = connections;
    final partBytes = (expectedBytes / n).ceil();
    final files = [for (var i = 0; i < n; i++) File('${target.path}.p$i')];
    final received = List<int>.filled(n, 0);
    var total = 0;
    var reportedAt = 0;

    Future<void> pull(int index) async {
      final start = index * partBytes;
      if (start >= expectedBytes) return;
      final end = math.min(expectedBytes, start + partBytes) - 1;
      final file = files[index];
      final client = http.Client();
      final clock = Stopwatch()..start();
      final sink = file.openWrite();
      try {
        final request = http.Request('GET', uri);
        request.headers.addAll(headers);
        request.headers['range'] = 'bytes=$start-$end';
        if (etag.isNotEmpty) request.headers['if-range'] = etag;
        final response = await client.send(request);
        // 回 200 说明服务端不认 Range（会吐整份文件）—— 这种链接不能按段拼，
        // 直接判失败，由 `download()` 退回单连接。
        if (response.statusCode != 206) {
          throw TransferFailed('HTTP ${response.statusCode}（不支持分片）');
        }
        await for (final chunk in response.stream) {
          if (isCanceled?.call() == true) throw const TransferCanceled();
          sink.add(chunk);
          received[index] += chunk.length;
          total += chunk.length;
          if (total - reportedAt >= 256 * 1024) {
            reportedAt = total;
            onProgress?.call(total);
          }
          if (maxBytesPerSecond > 0) {
            final expectedMs = total / maxBytesPerSecond * 1000;
            final ahead = expectedMs - clock.elapsedMilliseconds;
            if (ahead > 0) {
              await Future<void>.delayed(
                Duration(milliseconds: ahead.clamp(0, 1000).round()),
              );
            }
          }
        }
        await sink.flush();
        final got = await file.length();
        if (got != end - start + 1) {
          throw TransferFailed('分片长度对不上：$got / ${end - start + 1}');
        }
      } catch (_) {
        await _quietDelete(file);
        rethrow;
      } finally {
        try {
          await sink.close();
        } catch (_) {
          // 错误已由上面的分支上报
        }
        client.close();
      }
    }

    try {
      await Future.wait([for (var i = 0; i < n; i++) pull(i)]);
      // 顺序拼接，顺手算哈希：一段一段读，磁盘速度，几百 MB 也就一两秒
      final hasher = _StreamingSha256();
      final sink = target.openWrite();
      try {
        for (final file in files) {
          if (isCanceled?.call() == true) throw const TransferCanceled();
          if (!await file.exists()) continue;
          await for (final chunk in file.openRead()) {
            sink.add(chunk);
            hasher.add(chunk);
          }
        }
      } finally {
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {
          // 同上
        }
      }
      final actual = await target.length();
      if (expectedBytes > 0 && actual != expectedBytes) {
        throw TransferFailed('传入字节数对不上：$actual / $expectedBytes');
      }
      return TransferOutcome(bytes: actual, sha256: hasher.finish());
    } catch (_) {
      await _quietDelete(target);
      rethrow;
    } finally {
      for (final file in files) {
        await _quietDelete(file);
      }
    }
  }

  /// 抓一张图（封面 / 背景图）到 [target]；失败返回 false，不影响主流程
  static Future<bool> fetchToFile({
    required Uri uri,
    required Map<String, String> headers,
    required File target,
  }) async {
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', uri)..headers.addAll(headers));
      if (response.statusCode != 200) return false;
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      final sink = tmp.openWrite();
      await response.stream.pipe(sink);
      final length = await tmp.length();
      if (length <= 0) {
        await tmp.delete();
        return false;
      }
      await tmp.rename(target.path);
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}

class TransferOutcome {
  const TransferOutcome({required this.bytes, required this.sha256});

  final int bytes;
  final String sha256;
}

class TransferFailed implements Exception {
  TransferFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

class TransferCanceled implements Exception {
  const TransferCanceled();

  @override
  String toString() => '已取消';
}

/// `Sink<Digest>` 的最小实现：`startChunkedConversion` 要一个 sink 收最终摘要。
///
/// 不引 `package:convert` 的 `AccumulatorSink` —— 那会给一个只为存一个对象的依赖
/// 多压一个直接依赖（本仓库对 `depend_on_referenced_packages` 是有要求的）。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _StreamingSha256 {
  _DigestSink _digest = _DigestSink();
  late ByteConversionSink _sink = sha256.startChunkedConversion(_digest);

  void add(List<int> chunk) => _sink.add(chunk);

  void reset() {
    _digest = _DigestSink();
    _sink = sha256.startChunkedConversion(_digest);
  }

  String finish() {
    _sink.close();
    return '${_digest.value}';
  }
}
