import 'dart:async';

import 'display_caps_stub.dart'
    if (dart.library.io) 'display_caps_io.dart'
    as impl;

/// 片源 / 显示端的 HDR 等级。
///
/// 数值只用于比较「谁更高」：杜比视界 > HDR10+ > HDR10 > HLG > SDR。
/// 和 Android `Display.HdrCapabilities` 的四种常量一一对应，但顺序按
/// 实际观感排（HDR10+ 是动态元数据的 HDR10，比 HLG 强）。
enum HdrLevel {
  none(0, 'none'),
  hlg(1, 'hlg'),
  hdr10(2, 'hdr10'),
  hdr10plus(3, 'hdr10plus'),
  dolbyVision(4, 'dolbyVision');

  const HdrLevel(this.rank, this.reason);

  final int rank;

  /// 与服务端 `compat.reasons` 里的词表一致（`player.reason.<x>`）。
  final String reason;

  static HdrLevel ofReason(String reason) {
    for (final v in HdrLevel.values) {
      if (v.reason == reason) return v;
    }
    return HdrLevel.none;
  }

  /// 从 `compat.reasons` 里取最高档；没有 HDR 词条就是 SDR。
  static HdrLevel fromReasons(Iterable<String> reasons) {
    var best = HdrLevel.none;
    for (final r in reasons) {
      final v = ofReason(r);
      if (v.rank > best.rank) best = v;
    }
    return best;
  }

  bool get isHdr => this != HdrLevel.none;
}

/// 显示端（电视 / 显示器）能力。
class DisplayCaps {
  const DisplayCaps({this.hdrTypes = const <int>{}, this.known = false});

  /// Android `HdrCapabilities.getSupportedHdrTypes()` 的原始值。
  /// 空集合 + [known] = 读到了但一个都不支持（老电视 / 非 HDR 屏）。
  final Set<int> hdrTypes;

  /// 是否真的问到了系统（false = 平台没有这个通道，按「全支持」处理，不影响桌面）。
  final bool known;

  /// 桌面 / Web / iOS：不知道就当「能显示」，别把 HDR 片源强行转码。
  static const DisplayCaps unknown = DisplayCaps(known: false);

  /// 这台设备最高能显示到哪一档。`unknown` 返回 [HdrLevel.dolbyVision]，
  /// 让「不支持就别直连」的判断在非 Android 端自然失效。
  HdrLevel get maxHdr {
    if (!known) return HdrLevel.dolbyVision;
    if (hdrTypes.contains(1)) return HdrLevel.dolbyVision;
    if (hdrTypes.contains(4)) return HdrLevel.hdr10plus;
    if (hdrTypes.contains(2)) return HdrLevel.hdr10;
    if (hdrTypes.contains(3)) return HdrLevel.hlg;
    return HdrLevel.none;
  }

  /// 这份能力足以用来「拦下原片直连」吗。
  ///
  /// Android 的 `getSupportedHdrTypes()` 在不少电视上会返回空数组（和当前
  /// HDMI 模式 / 系统版本有关），但屏幕本身是 DV / HDR10+ 的。拿空数组当
  /// 「这块屏什么 HDR 都不支持」会把所有原片压成 SDR，损失比误判大得多；
  /// 只有真的读到了具体类型才据此降级。
  bool get trustworthy => known && hdrTypes.isNotEmpty;

  /// 电视能不能直接显示这个等级的片源。
  bool supports(HdrLevel source) => source.rank <= maxHdr.rank;
}

/// 测试注入点：真机没在手边时用它替换探测结果（不参与正式逻辑）。
DisplayCaps? debugDisplayCapsOverride;

/// 读一次系统 HDR 能力；非 Android / 读失败返回 [DisplayCaps.unknown]。
Future<DisplayCaps> readDisplayCaps() async =>
    debugDisplayCapsOverride ?? await impl.readDisplayCaps();
