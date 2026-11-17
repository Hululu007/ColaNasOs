import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 单连接 HTTP Range 下载 + 边下边算 SHA-256。
///
/// 第一期只做单连接（不做多线程分片）：NAS 在内网，瓶颈通常在服务端转码而不是
/// 带宽，多连接只会把请求排队搞乱，还让「暂停 / 续传」的边界更难对齐。
class OfflineTransfer {
  OfflineTransfer._();

  /// 把 `uri` 的内容写进 [target]（`.part` 临时文件）。
  ///
  /// - [resumeFrom] > 0 时先给已有前缀算一遍哈希，再带 `Range` + `If-Range` 续传；
  /// - 服务端回 200（说明产物变了 / 不认 Range）就丢弃已有字节从头下；
  /// - [onProgress] 每收一块回调一次（调用方自己去抖）。
  static Future<TransferOutcome> download({
    required Uri uri,
    required Map<String, String> headers,
    required File target,
    required String etag,
    required int expectedBytes,
    int resumeFrom = 0,
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

      await for (final chunk in response.stream) {
        if (isCanceled?.call() == true) {
          throw const TransferCanceled();
        }
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
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
