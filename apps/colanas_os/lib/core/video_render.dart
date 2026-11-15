import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:media_kit/media_kit.dart';

/// 播放渲染能力与 HDR 色调映射（PC / TV 共用）。
///
/// 为什么需要这一层：`media_kit` 自带的 Windows libmpv 是 **mpv 0.36.0**，
/// 编译参数里 `-Dlibplacebo=disabled`（可以在 `libmpv-2.dll` 的构建串里查到）。
/// 于是：
///
/// - 没有 `vo=gpu-next`，也没有 libplacebo 的动态色调映射；
/// - 没有 Dolby Vision RPU 解析，P5 直接播出来是紫 / 荧光绿；
/// - `media_kit` 初始化时还把 `hdr-compute-peak` 显式设成 `no`（省 GPU），
///   HDR10 直连会发灰、高光糊成一片。
///
/// 所以「原画」在桌面上只能是「先确认这台机器真的能正确显示这个片源」才直连。
/// 这个类的职责只有两件：
///   1. 探测运行时 libmpv 的版本 / 可用 VO（写进播放信息面板，排障用）；
///   2. 下发正确的 SDR 色调映射参数，并读回真正生效的算法。
///
/// 注意：**不要**在这里设置 `vo`。`media_kit_video` 用 libmpv 的 render API
/// 出纹理，mpv 只接受 `vo=libmpv`；把它改成 `gpu-next` 会让
/// `mpv_render_context_create` 直接失败（黑屏 + 有声音）。想用 gpu-next /
/// libplacebo 必须换渲染后端，不是改一个属性就能做到的。
class VideoRenderCaps {
  const VideoRenderCaps({
    this.mpvVersion = '',
    this.voChoices = const <String>[],
    this.toneMapping = '',
  });

  /// `mpv-version` 原值，例如 `mpv 0.36.0`；Web 端为空。
  final String mpvVersion;

  /// libmpv 编译进来的 VO 清单（`option-info/vo/choices`）。仅用于展示。
  final List<String> voChoices;

  /// 真正生效的色调映射算法（读回失败时为空）。
  final String toneMapping;

  /// 是否运行在原生 libmpv 上（Web 用浏览器解码，不适用）。
  bool get native => !kIsWeb && mpvVersion.isNotEmpty;

  /// 这台机器能不能直接正确播放 Dolby Vision。
  ///
  /// 结论：**不能**。`media_kit` 的纹理走 `vo=libmpv`（vo_gpu 渲染器），
  /// DV 的 IPT-PQ 需要 libplacebo 解析 RPU 才能还原；这个构建两者都没有。
  /// 所以 DV 片源一律走服务端色调映射转码（服务端已验证 DV P5 色彩正确），
  /// 而不是让用户对着紫画面猜。
  bool get dolbyVisionDirect => false;

  /// 直连时能不能把 HDR10 / HLG 正确压到 SDR：mpv 的 vo_gpu 有 bt.2390，
  /// 只要 `hdr-compute-peak` 打开就能算动态峰值，不需要 libplacebo。
  bool get hdrDirect => native;

  /// 播放信息面板里显示的渲染器名字。
  String get renderer {
    if (kIsWeb) return 'browser';
    if (!native) return 'libmpv';
    return voChoices.contains('gpu-next')
        ? 'libmpv · gpu-next available'
        : 'libmpv';
  }

  /// 纯诊断用的短标签：`mpv 0.36.0 / bt.2390`。
  String get summary {
    if (kIsWeb) return 'browser';
    final v = mpvVersion.isEmpty ? 'libmpv' : mpvVersion;
    return toneMapping.isEmpty ? v : '$v / $toneMapping';
  }

  /// 探测 + 下发色调映射。返回带 `toneMapping` 的新实例。
  ///
  /// 所有 `setProperty` 都是「设了就算，读不回就当没设」：libmpv 对不认识的
  /// 属性/取值只会打日志、不抛异常，把它当致命错误会把播放卡死。
  static Future<VideoRenderCaps> setup(Player player) async {
    if (kIsWeb) return const VideoRenderCaps();
    dynamic platform;
    try {
      platform = player.platform;
    } catch (_) {
      return const VideoRenderCaps();
    }
    if (platform == null) return const VideoRenderCaps();

    Future<String> read(String name) async {
      try {
        // ignore: avoid_dynamic_calls
        final value = await platform.getProperty(name) as String?;
        return (value ?? '').trim();
      } catch (_) {
        return '';
      }
    }

    Future<void> write(String name, String value) async {
      try {
        // ignore: avoid_dynamic_calls
        await platform.setProperty(name, value);
      } catch (_) {
        // 老构建不认识的属性直接跳过
      }
    }

    final version = await read('mpv-version');
    final voRaw = await read('option-info/vo/choices');
    final vos = voRaw
        .split(RegExp(r'[,;]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    // vo_gpu 支持的算法里 bt.2390 最稳；gpu-next 才有 bt.2446a。
    // 这里按「有没有 gpu-next」选，但渲染仍走 libmpv，所以只影响直连的 HDR10。
    final wantTm = vos.contains('gpu-next') ? 'bt.2446a' : 'bt.2390';
    await write('tone-mapping', wantTm);
    // media_kit 默认把它关了；不开就没有动态峰值，HDR 直连必发灰。
    await write('hdr-compute-peak', 'yes');
    await write('target-peak', 'auto');
    // 10bit → 8bit 不做抖动会出色带（media_kit 默认 dither=no）
    await write('dither', 'fruit');

    var applied = await read('tone-mapping');
    // 有的构建把 auto 解析成具体算法，读回来是 `bt.2390` 这种就照实记。
    if (applied.isEmpty || applied == 'auto') applied = wantTm;

    return VideoRenderCaps(
      mpvVersion: version,
      voChoices: vos,
      toneMapping: applied,
    );
  }
}
