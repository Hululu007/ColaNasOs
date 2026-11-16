/// 性能诊断的 Web 实现：浏览器里不采设备细节、不落盘，只走服务端上报。
Future<Map<String, Object?>> collectDeviceInfo() async => <String, Object?>{
      'kind': 'web',
    };

Future<String?> appendPerfLine(String line) async => null;

Future<String?> perfLogPath() async => null;
