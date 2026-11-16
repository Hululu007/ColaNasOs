import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:nas_core/nas_core.dart';

import 'perf_diagnostics.dart';

/// 跨平台 HTTP 传输层：桌面 / 移动走 `IOClient`，Web（浏览器与 Electron 壳里
/// 加载的同一份 Flutter Web 产物）走 `BrowserClient`。
///
/// 为什么不用 `nas_core` 的 [IoTransport]：它基于 `dart:io`，在 Web 上一调用就抛
/// `Unsupported operation: Platform._version` —— 表现为登录页探测静默失败、
/// 「首次安装」永远不出现、登录按钮点了也没反应。
class HttpTransport implements Transport {
  HttpTransport({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;
  final http.Client _client = http.Client();

  @override
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final request = http.Request(method, url);
    if (headers != null) request.headers.addAll(headers);
    // 每个请求都带上「客户端机器标识」：同步任务按「用户 + 机器」隔离，
    // 同一台机器上的主客户端与独立同步客户端算出同一个值，共享任务列表。
    final clientId = ColanasClientId.value;
    if (clientId.isNotEmpty &&
        !request.headers.containsKey('x-colanas-client')) {
      request.headers['x-colanas-client'] = clientId;
    }
    if (body != null && body.isNotEmpty) request.bodyBytes = body;

    // 接口耗时/字节数：诊断开启时进报表；关闭时只在慢请求/大响应留一行日志。
    final clock = Stopwatch()..start();
    var status = 0;
    var bytes = 0;
    try {
      final response = await _client.send(request).timeout(timeout);
      final data = await response.stream.toBytes().timeout(timeout);
      status = response.statusCode;
      bytes = data.length;
      clock.stop();
      PerfDiagnostics.instance.recordRequest(
        method: method,
        path: url.path,
        status: status,
        ms: clock.elapsedMilliseconds,
        bytes: bytes,
      );
      return ApiResponse(
        statusCode: response.statusCode,
        body: data,
        headers: response.headers,
      );
    } catch (e) {
      clock.stop();
      PerfDiagnostics.instance.recordRequest(
        method: method,
        path: url.path,
        status: status == 0 ? 599 : status,
        ms: clock.elapsedMilliseconds,
        bytes: bytes,
      );
      rethrow;
    }
  }

  @override
  void close() => _client.close();
}
