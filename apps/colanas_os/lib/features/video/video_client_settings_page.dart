import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/codec_support.dart';
import '../../core/play_quality.dart';
import '../../core/play_preferences.dart';
import 'offline/offline_entry.dart';

/// 客户端设置：**只影响当前这台机器 / 这个浏览器**。
///
/// 与「影视设置」的分界：
///   - 影视设置 = 服务端级（TMDB、字幕抓取、所有客户端共享）
///   - 客户端设置 = 播放偏好（画质 / 编码 / 音频），存本地，不写库
///
/// 音频两项是「覆盖」语义：关 = 不传参数 = 跟随库级 `audio_normalize` 开关，
/// 打开才在本次会话强制生效。默认值与改动前完全一致。
///
/// 编码一项只列出**当前设备真能解**的编码。以前是按平台一刀切
/// （浏览器一律只剩 H.264），理由是「hls.js 建不出 AV1 / HEVC 的 SourceBuffer」——
/// 2026-11-05 用真 Chrome + hls.js 1.4.10 复测推翻了这个前提，改成问
/// `MediaSource.isTypeSupported`：浏览器说能解就给选，说不能解就不列。
/// 已存的偏好若在本机解不了，**只影响显示**（回落成 H.264），不改写用户存的值。
class VideoClientSettingsPage extends StatefulWidget {
  const VideoClientSettingsPage({super.key});

  @override
  State<VideoClientSettingsPage> createState() => _VideoClientSettingsPageState();
}

class _VideoClientSettingsPageState extends State<VideoClientSettingsPage> {
  @override
  void initState() {
    super.initState();
    // 只有 PC / Android 有本地库；Web 上 `offlineRootPath()` 返回 null，段整块隐藏
    _loadOffline();
  }

  late String _preset = PlayPreferences.preset;

  /// 存的值在本机解不出来时显示成 H.264，避免下拉框的 value 不在 items 里。
  late String _codec = _playableOrDefault(PlayPreferences.codec);

  static String _playableOrDefault(String codec) =>
      codecPlayable(codec) ? codec : 'h264';

  late bool _normalize = PlayPreferences.audioNormalize;
  late bool _downmix = PlayPreferences.audioDownmix;
  late int _lead = PlayPreferences.leadMinutes;

  String? _offlinePath;
  int _offlineUsed = 0;
  int _offlineCount = 0;
  bool _migrating = false;
  String _migrateLabel = '';

  /// 提前转码时长的可选档；默认选中 [PlayPreferences.defaultLeadMinutes]（3 分钟）。
  /// 2026-11-16 起不再提供「整片一次转完」（0）：整片模式没有 `-t` 终点，
  /// 响度归一时会写出缺音轨的首片，浏览器播几秒就卡死。
  static const _leadOptions = [1, 3, 5, 10, 20];

  /// 本机有编码被砍掉时才提示原因，全都支持就别啰嗦。
  bool get _hasUnplayableCodec => playableCodecs().length < playCodecs.length;

  /// 当前档位规格（height / 各编码码率 / 是否原画）
  PlayQualityPreset get _presetSpec =>
      playQualityPresetOf(_preset) ?? playQualityPresets.first;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        NasTokens.spaceMd,
        NasTokens.spaceLg,
        NasTokens.spaceXl,
      ),
      children: [
        Row(
          children: [
            Icon(Icons.devices, size: 16, color: context.nasTextSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('video.client.localOnly'),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ),
          ],
        ),

        _section(tr('video.client.group.play')),
        _setting(
          title: tr('video.client.playQuality'),
          // 原画时把「不转码」写进这一行，不再单独占一行
          hint: _presetSpec.copy
              ? tr('video.client.copyNoTranscode')
              : tr('video.client.playQualityHint'),
          trailing: NasDropdown<String>(
            value: _preset,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final p in playQualityPresets)
                DropdownMenuItem<String>(
                  value: p.key,
                  // 一档一行：`1080P 1.4Mbps`。
                  // 以前是「label · bitrateLabelFor」两段（1080P 3M · 1.4 Mbps），
                  // 同一档位并排两个码率，看着像重复，用户 2026-11-05 明确要求只留
                  // 当前编码下真正生效的那个；H.264 的旧数字已从 label 里去掉。
                  child: Text(p.labelFor(_codec)),
                ),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _preset = v);
              await PlayPreferences.savePreset(v);
            },
          ),
        ),
        _setting(
          title: tr('video.client.codec'),
          hint: _hasUnplayableCodec
              ? tr('video.client.codecUnavailable')
              : tr('video.client.codecHint'),
          trailing: NasDropdown<String>(
            value: _codec,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              // 与详情页 / 播放器的编码菜单同一条规则：只列本机解得出来的
              for (final c in playableCodecs())
                DropdownMenuItem<String>(value: c.key, child: Text(c.label)),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _codec = v);
              await PlayPreferences.saveCodec(v);
            },
          ),
        ),

        _setting(
          title: tr('video.client.leadMinutes'),
          hint: tr('video.client.leadMinutesHint'),
          trailing: NasDropdown<int>(
            value: _leadOptions.contains(_lead) ? _lead : PlayPreferences.defaultLeadMinutes,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final n in _leadOptions)
                DropdownMenuItem<int>(
                  value: n,
                  child: Text(tr('video.client.leadN', {'n': '$n'})),
                ),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _lead = v);
              await PlayPreferences.saveLeadMinutes(v);
            },
          ),
        ),

        _section(tr('video.client.group.audio')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _normalize,
          title: Text(tr('video.client.audioNormalize')),
          subtitle: Text(
            tr('video.client.audioNormalizeHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          onChanged: (v) async {
            setState(() => _normalize = v);
            await PlayPreferences.saveAudio(normalize: v);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _downmix,
          title: Text(tr('video.client.downmix')),
          subtitle: Text(
            tr('video.client.downmixHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          onChanged: (v) async {
            setState(() => _downmix = v);
            await PlayPreferences.saveAudio(downmix: v);
          },
        ),
        if (offlineSupported) ..._offlineSection(),
      ],
    );
  }

  /// 离线下载：存储位置 / 占用 / 一键清空。
  ///
  /// 这里只读展示路径，不做「换目录」—— 换目录必然要迁移已有文件（几 GB 起），
  /// 迁移中途失败还得能回退，属于存储管理单独一版的事（P7），
  /// 给一个半成品按钮比不给更糟。
  List<Widget> _offlineSection() {
    final path = _offlinePath;
    final canChangeRoot =
        defaultTargetPlatform != TargetPlatform.android;
    return [
      _section(tr('video.offline.title')),
      _setting(
        title: tr('video.offline.storage'),
        hint: path == null
            ? tr('video.offline.storageHint')
            : '$path\n${tr('video.offline.storageHint')}',
        trailing: canChangeRoot
            ? TextButton(
                onPressed: _migrating ? null : _changeRoot,
                child: Text(
                  _migrating && _migrateLabel.isNotEmpty
                      ? _migrateLabel
                      : tr('video.offline.changeRoot'),
                ),
              )
            : const SizedBox.shrink(),
      ),
      _setting(
        title: tr('video.offline.usage', {
          'size': formatBytes(_offlineUsed),
          'n': '$_offlineCount',
        }),
        hint: tr('video.offline.settingsHint'),
        trailing: TextButton(
          onPressed: (_migrating || _offlineCount == 0) ? null : _clearOffline,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(tr('video.offline.clearAll')),
        ),
      ),
    ];
  }

  /// 换目录：选目录 → 确认 → 迁移（逐文件拷贝并校验，失败不动原目录）
  Future<void> _changeRoot() async {
    final target = await offlinePickRoot();
    if (target == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.offline.changeRootTitle')),
        content: Text(
          tr('video.offline.changeRootBody', {
            'n': '$_offlineCount',
            'size': formatBytes(_offlineUsed),
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('video.offline.changeRoot')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _migrating = true;
      _migrateLabel = '';
    });
    final error = await offlineMigrateRoot(
      target,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _migrateLabel = tr('video.offline.migrating', {
            'done': '$done',
            'total': '$total',
          });
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _migrating = false;
      _migrateLabel = '';
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          error == null
              ? tr('video.offline.migrateDone')
              : tr('video.offline.migrateFailed', {'error': error}),
        ),
      ),
    );
    await _loadOffline();
  }

  Future<void> _loadOffline() async {
    try {
      final path = await offlineRootPath();
      final used = await offlineUsedBytes();
      final count = await offlineItemCount();
      if (!mounted) return;
      setState(() {
        _offlinePath = path;
        _offlineUsed = used;
        _offlineCount = count;
      });
    } catch (_) {
      // 读不到本地库：按空显示，不影响其它设置项
    }
  }

  Future<void> _clearOffline() async {
    final count = _offlineCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.offline.deleteTitle')),
        content: Text(tr('video.offline.deleteBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('video.offline.clearAll')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await offlineClearAll();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(tr('video.offline.clearDone', {'n': '$count'}))),
    );
    await _loadOffline();
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: NasTokens.spaceLg, bottom: NasTokens.spaceXs),
        child: Text(
          title,
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            fontWeight: FontWeight.w600,
            color: context.nasTextSecondary,
          ),
        ),
      );

  /// 一行设置：左标题 + 提示，右控件（下拉 / 开关）。窄屏也不挤，提示可换行。
  Widget _setting({required String title, required String hint, required Widget trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          trailing,
        ],
      ),
    );
  }
}
