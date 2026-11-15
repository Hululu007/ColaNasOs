import 'display_caps.dart';

/// Web：浏览器不暴露显示端的 HDR 能力，一律当「未知」。
Future<DisplayCaps> readDisplayCaps() async => DisplayCaps.unknown;
