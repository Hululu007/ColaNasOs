import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_version.dart';
import '../../core/codec_support.dart';
import '../../core/play_preferences.dart';
import '../../core/play_quality.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../update/tv_update_dialog.dart';
import '../update/update_service.dart';
import 'tv_focus.dart';
import 'tv_option_dialog.dart';

/// TV「我的」分区：账号 / 服务器 / **播放默认值** / 退出登录。
///
/// 加「默认码率 / 默认解码方式」的原因：电视上没有画质下拉框，播放中改档又
/// 要点开控制层；把默认值放到「我的」里，开机就能定好，之后每部片直接按它播。
/// 两项都用遥控器选项弹窗（方向键 + OK + 返回），不依赖触摸。
///
/// 退出登录只清本机凭证（token / 密码 / 服务器地址），回到登录页的
/// 「选择服务器」步骤；「更换服务器 / 重新登录」保留服务器地址，登录页会
/// 自动重连到原服务器并显示登录表单。
class TvProfileSection extends StatefulWidget {
  const TvProfileSection({super.key, this.firstFocusNode});

  final FocusNode? firstFocusNode;

  @override
  State<TvProfileSection> createState() => _TvProfileSectionState();
}

class _TvProfileSectionState extends State<TvProfileSection> {
  String get _account {
    final live = (ApiSession.instance.username ?? '').trim();
    if (live.isNotEmpty) return live;
    final saved = (SettingsStore.instance.getString('auth.username') ?? '')
        .trim();
    return saved.isEmpty ? '-' : saved;
  }

  /// 当前生效的默认转码画质；原码策略不受这个档位影响。
  String get _preset => PlayPreferences.savedPreset ?? PlayPreferences.preset;

  String get _presetLabel =>
      playQualityPresetOf(_preset)?.labelFor(
        PlayPreferences.codec == 'original'
            ? defaultTranscodeCodec()
            : PlayPreferences.codec,
      ) ??
      _preset;

  String get _codecLabel =>
      playCodecOf(PlayPreferences.codec)?.label ?? PlayPreferences.codec;

  String _normalizeLabel(AudioNormalizeMode mode) => switch (mode) {
    AudioNormalizeMode.inherit => tr('video.client.audioNormalizeInherit'),
    AudioNormalizeMode.enabled => tr('video.client.audioNormalizeForceOn'),
    AudioNormalizeMode.disabled => tr('video.client.audioNormalizeForceOff'),
  };

  Future<void> _pickNormalize() async {
    final current = PlayPreferences.audioNormalizeMode;
    final picked = await showTvOptionDialog(
      context,
      title: tr('video.client.audioNormalize'),
      hint: tr('video.client.audioNormalizeHint'),
      columns: 1,
      items: [
        for (final mode in AudioNormalizeMode.values)
          TvOptionItem(
            value: mode.name,
            label: _normalizeLabel(mode),
            selected: current == mode,
          ),
      ],
    );
    if (picked == null) return;
    final mode = AudioNormalizeMode.values.firstWhere(
      (mode) => mode.name == picked,
    );
    await PlayPreferences.saveAudio(normalizeMode: mode);
    if (mounted) setState(() {});
  }

  Future<void> _toggleToneMap(bool value) async {
    await PlayPreferences.saveToneMap(value);
    if (mounted) setState(() {});
  }

  /// 「混为立体声」：电视接双声道音箱 / 回音壁时必须能手动降混。
  /// 默认关（不勾），勾上就是把 5.1 / 7.1 压成两声道。
  Future<void> _toggleDownmix(bool value) async {
    await PlayPreferences.saveAudio(downmix: value);
    if (mounted) setState(() {});
  }

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _TvConfirmDialog(
        titleKey: 'tv.profile.logout',
        messageKey: 'tv.profile.logoutConfirm',
        confirmKey: 'tv.profile.logout',
      ),
    );
    if (ok != true) return;
    // 先清服务器地址：LoginPage 初始化时看到空地址会停在「选择服务器」步骤。
    await SettingsStore.instance.setString('auth.server', null);
    await ApiSession.instance.logout();
  }

  Future<void> _relogin() async {
    // 保留服务器地址，登录页会自动重连并显示登录表单。
    await ApiSession.instance.logout();
  }

  Future<void> _pickPreset() async {
    final picked = await showTvOptionDialog(
      context,
      title: tr('tv.profile.defaultPreset'),
      hint: tr('tv.profile.defaultPresetHint'),
      columns: 3,
      items: [
        for (final p in playQualityPresets.where((p) => !p.copy))
          TvOptionItem(
            value: p.key,
            label: p.labelFor(
              PlayPreferences.codec == 'original'
                  ? defaultTranscodeCodec()
                  : PlayPreferences.codec,
            ),
            selected: _preset == p.key,
          ),
      ],
    );
    if (picked == null) return;
    await PlayPreferences.savePreset(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickCodec() async {
    final picked = await showTvOptionDialog(
      context,
      title: tr('tv.profile.defaultCodec'),
      hint: tr('tv.profile.defaultCodecHint'),
      columns: 2,
      items: [
        for (final c in playableCodecs())
          TvOptionItem(
            value: c.key,
            label: c.label,
            subtitle: c.transcode ? c.container.toUpperCase() : '',
            selected: PlayPreferences.codec == c.key,
          ),
      ],
    );
    if (picked == null) return;
    await PlayPreferences.saveCodec(picked);
    if (mounted) setState(() {});
  }

  /// 「检查更新」这一行右侧的状态文字
  String _updateValue(UpdateStatus status, ClientUpdate? info) {
    if (status.phase == UpdatePhase.checking) return tr('update.checking');
    if (status.phase == UpdatePhase.downloading) {
      return UpdateService.formatBytes(status.loaded);
    }
    if (status.phase == UpdatePhase.verifying) return tr('update.verifying');
    if (status.phase == UpdatePhase.installing) return tr('update.installing');
    if (status.phase == UpdatePhase.failed) return tr('update.checkFailed');
    if (info != null && info.hasUpdate) {
      return tr('update.clientAvailable', {'version': info.latestSemver});
    }
    return status.phase == UpdatePhase.idle && info == null
        ? tr('update.check')
        : tr('update.none');
  }

  /// 点「检查更新」：没查过就先查，查到直接进更新弹窗（遥控器少按一次）
  Future<void> _onCheckUpdate(
    UpdateStatus status,
    ClientUpdate? info,
    bool ready,
  ) async {
    if (status.busy) {
      // 正在下载：直接把弹窗叫回来，别让用户以为卡住了
      if (info == null || !mounted) return;
      await showTvUpdateDialog(context, info);
      return;
    }
    if (ready && info != null) {
      await showTvUpdateDialog(context, info);
      return;
    }
    await UpdateService.instance.check(force: true);
    if (!mounted) return;
    final found = UpdateService.instance.available.value;
    if (found != null && found.hasUpdate) {
      await showTvUpdateDialog(context, found);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final server = ApiSession.instance.baseUrl;
    final host = ApiSession.instance.hostName;
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: m.px(8), vertical: m.px(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('tv.profile.title'),
            style: TextStyle(
              fontSize: m.px(30),
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          SizedBox(height: m.px(18)),
          _InfoRow(
            icon: Icons.person_outline_rounded,
            label: tr('tv.profile.account'),
            value: _account,
          ),
          SizedBox(height: m.px(12)),
          _InfoRow(
            icon: Icons.dns_outlined,
            label: tr('tv.profile.server'),
            value: host.isEmpty ? server : '$server · $host',
          ),
          SizedBox(height: m.px(12)),
          // 检查更新：大屏上没有「设置 → 关于」，更新入口只能放这里。
          // 行本身用 TvFocusCard（遥控器可达），状态文字实时跟着下载/检查进度走。
          ValueListenableBuilder<UpdateStatus>(
            valueListenable: UpdateService.instance.status,
            builder: (context, status, _) {
              final info = UpdateService.instance.available.value;
              final ready = info != null && info.hasUpdate;
              return _SettingRow(
                icon: Icons.system_update_alt_rounded,
                label: tr('update.check'),
                hint: tr('update.tvHint'),
                value: _updateValue(status, info),
                onTap: () => _onCheckUpdate(status, info, ready),
              );
            },
          ),
          SizedBox(height: m.px(12)),
          // 版本号与项目主页：大屏上没有「设置 → 关于」，报问题时同样要能一眼看到。
          // 电视不保证有浏览器，所以地址只展示不点开（手机上照抄即可）。
          _InfoRow(
            icon: Icons.info_outline_rounded,
            label: tr('tv.profile.version'),
            value: 'v$kAppVersion',
          ),
          SizedBox(height: m.px(12)),
          _InfoRow(
            icon: Icons.code_rounded,
            label: tr('settings.projectHome'),
            value: kProjectUrl,
          ),
          SizedBox(height: m.px(22)),
          _SettingRow(
            icon: Icons.high_quality_outlined,
            label: tr('tv.profile.defaultPreset'),
            hint: tr('tv.profile.defaultPresetHint'),
            value: _presetLabel,
            focusNode: widget.firstFocusNode,
            onTap: _pickPreset,
          ),
          SizedBox(height: m.px(12)),
          _SettingRow(
            icon: Icons.memory_rounded,
            label: tr('tv.profile.defaultCodec'),
            hint: tr('tv.profile.defaultCodecHint'),
            value: _codecLabel,
            onTap: _pickCodec,
          ),
          SizedBox(height: m.px(12)),
          _ToggleSettingRow(
            icon: Icons.hdr_on_rounded,
            label: tr('video.client.toneMap'),
            hint: tr('video.client.toneMapHint'),
            value: PlayPreferences.toneMap,
            onChanged: _toggleToneMap,
          ),
          SizedBox(height: m.px(12)),
          _SettingRow(
            icon: Icons.volume_up_outlined,
            label: tr('video.client.audioNormalize'),
            hint: tr('video.client.audioNormalizeHint'),
            value: _normalizeLabel(PlayPreferences.audioNormalizeMode),
            onTap: _pickNormalize,
          ),
          SizedBox(height: m.px(12)),
          // 降混：电视接的是双声道音箱 / 回音壁时，5.1 / 7.1 的片源必须能压成
          // 两声道，否则人声对白被混进中置声道，听起来就是「背景声大、说话小」。
          // 默认不勾（与其它端一致）；勾上后由服务端把音频轨降混成 AAC 立体声。
          _ToggleSettingRow(
            icon: Icons.surround_sound_outlined,
            label: tr('video.client.downmix'),
            hint: tr('video.client.downmixHint'),
            value: PlayPreferences.audioDownmix,
            onChanged: _toggleDownmix,
          ),
          SizedBox(height: m.px(28)),
          Wrap(
            spacing: m.px(16),
            runSpacing: m.px(12),
            children: [
              TvFocusCard(
                onTap: () => _logout(context),
                radius: m.px(14),
                focusScale: 1.03,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.px(26),
                    vertical: m.px(14),
                  ),
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(m.px(14)),
                    border: Border.all(
                      color: scheme.error.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.logout_rounded,
                        size: m.px(20),
                        color: scheme.error,
                      ),
                      SizedBox(width: m.px(8)),
                      Text(
                        tr('tv.profile.logout'),
                        style: TextStyle(
                          fontSize: m.px(17),
                          fontWeight: FontWeight.w700,
                          color: scheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              TvFocusCard(
                onTap: _relogin,
                radius: m.px(14),
                focusScale: 1.03,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.px(26),
                    vertical: m.px(14),
                  ),
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(m.px(14)),
                    border: Border.all(
                      color: scheme.onSurface.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.swap_horiz_rounded,
                        size: m.px(20),
                        color: scheme.onSurface,
                      ),
                      SizedBox(width: m.px(8)),
                      Text(
                        tr('tv.profile.relogin'),
                        style: TextStyle(
                          fontSize: m.px(17),
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一行可点设置：左侧图标 + 名称 / 说明，右侧当前值 + 箭头。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.value,
    required this.onTap,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final String hint;
  final String value;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      radius: m.px(14),
      focusScale: 1.02,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: m.px(18), vertical: m.px(14)),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(m.px(14)),
        ),
        child: Row(
          children: [
            Icon(icon, size: m.px(22), color: scheme.onSurfaceVariant),
            SizedBox(width: m.px(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: m.px(18),
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  SizedBox(height: m.px(4)),
                  Text(
                    hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.px(13),
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: m.px(16)),
            Text(
              value,
              style: TextStyle(
                fontSize: m.px(18),
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            SizedBox(width: m.px(6)),
            Icon(
              Icons.chevron_right_rounded,
              size: m.px(22),
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleSettingRow extends StatelessWidget {
  const _ToggleSettingRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return TvFocusCard(
      onTap: () => onChanged(!value),
      radius: m.px(14),
      focusScale: 1.02,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: m.px(18), vertical: m.px(14)),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(m.px(14)),
        ),
        child: Row(
          children: [
            Icon(icon, size: m.px(22), color: scheme.onSurfaceVariant),
            SizedBox(width: m.px(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: m.px(18),
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  SizedBox(height: m.px(4)),
                  Text(
                    hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.px(13),
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: m.px(16)),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: m.px(18), vertical: m.px(14)),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(m.px(14)),
      ),
      child: Row(
        children: [
          Icon(icon, size: m.px(22), color: scheme.onSurfaceVariant),
          SizedBox(width: m.px(14)),
          SizedBox(
            width: m.px(120),
            child: Text(
              label,
              style: TextStyle(
                fontSize: m.px(15),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.px(18),
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TvConfirmDialog extends StatelessWidget {
  const _TvConfirmDialog({
    required this.titleKey,
    required this.messageKey,
    required this.confirmKey,
  });

  final String titleKey;
  final String messageKey;
  final String confirmKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            // 遥控器 OK（select）不一定被默认快捷键映射成 ActivateIntent，
            // 这里统一派发一次，保证两个按钮都能确认。
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final key = event.logicalKey;
              final isOk =
                  key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.gameButtonA;
              if (!isOk) return KeyEventResult.ignored;
              final focus = FocusManager.instance.primaryFocus?.context;
              if (focus == null) return KeyEventResult.ignored;
              Actions.maybeInvoke(focus, const ActivateIntent());
              return KeyEventResult.handled;
            },
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(titleKey),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr(messageKey),
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _DialogButton(
                        label: tr('common.cancel'),
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                      const SizedBox(width: 12),
                      _DialogButton(
                        label: tr(confirmKey),
                        autofocus: true,
                        danger: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.onTap,
    this.autofocus = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool autofocus;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? scheme.error : scheme.onSurface;
    return TvFocusCard(
      autofocus: autofocus,
      onTap: onTap,
      radius: 12,
      focusScale: 1.03,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: danger
              ? scheme.error.withValues(alpha: 0.16)
              : scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}
