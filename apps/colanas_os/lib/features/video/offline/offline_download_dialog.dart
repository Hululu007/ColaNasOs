import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/codec_support.dart';
import '../../../core/play_quality.dart';
import '../../../core/session.dart';
import '../video_card.dart';
import 'offline_download_manager.dart';
import 'offline_models.dart';

/// 下载配置弹窗（PC Dialog / Android BottomSheet）。
///
/// **所有数字都来自服务端 `/quote`**：编码换档后的推荐码率、片源撑不住某档时的
/// 收敛（720p 片源选 1080P → 自动落到 720P）、预估体积。客户端不自己算一份，
/// 否则两端算法一漂，用户看到 1.9 GB 实际下出来 2.6 GB。
///
/// 输入一变就重新 quote（250ms 去抖）：本地没有那份「档位 × 编码」表的权威副本，
/// 硬编码只会让参数联动在两个地方各错一半。
Future<void> openOfflineDownloadDialog(
  BuildContext context,
  VideoItem item, {
  String? libraryName,
  String? seriesTitle,
  int? totalEpisodes,
}) async {
  if (!OfflineDownloadManager.instance.supported) {
    _toast(context, tr('video.offline.unsupported'));
    return;
  }
  final store = await OfflineDownloadManager.instance.ensureStore();

  // 已下载过的：拿本地那条记录做「当前版本」对照
  final existing = store.item(item.id);

  if (!context.mounted) return;
  final content = _DownloadSheet(
    item: item,
    libraryName: libraryName ?? '',
    seriesTitle: seriesTitle,
    totalEpisodes: totalEpisodes,
    existing: existing,
  );
  if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(child: content),
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: content,
        ),
      ),
    );
  }
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
}

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({
    required this.item,
    required this.libraryName,
    required this.seriesTitle,
    required this.totalEpisodes,
    required this.existing,
  });

  final VideoItem item;
  final String libraryName;
  final String? seriesTitle;
  final int? totalEpisodes;
  final LocalMediaItem? existing;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  OfflineQuoteResponse? _quote;

  late String _codec = 'original';
  late int _height = 0;
  late String _quality = 'standard';

  /// 默认内挂：剧集没字幕基本没法看；源片没有字幕轨时服务端 `-map 0:s?` 是空操作。
  /// 原画档由服务端强制走 `none`（`-c copy` 本来就把字幕带过去了）。
  String _subtitleMode = 'embed';

  /// 字幕探测：内嵌文本轨 / 外挂字幕文件各几条。
  ///
  /// 服务端只把**文本类**内嵌轨列进 `#embedded:<n>`（图形字幕 PGS / VobSub
  /// 转不了，内挂必然失败），外挂字幕是同目录同主名的 srt / ass。
  /// 有了这两个数才能判断「这部片子到底要不要下字幕」：
  /// 有文本内嵌轨 → 内挂；只有外挂 → 外挂；都没有 → 这片子没字幕可下。
  int _subEmbedded = 0;
  int _subExternal = 0;
  bool _subChecked = false;

  /// 用户手动改过字幕选项：之后不再自动改默认值。
  bool _subtitleTouched = false;
  final TextEditingController _kbps = TextEditingController();

  /// 手填值（空 = 用服务端推荐）
  bool _manualKbps = false;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // 默认用原画：不重编码、最快、体积最省，且画质无损
    _quoteNow();
    // 字幕情况：决定「要不要下字幕」「下哪种」，探测在后台跑，不挡界面
    _probeSubtitles();
  }

  /// 探测这部片子有哪些字幕可用（内嵌文本轨 / 外挂字幕文件）。
  ///
  /// 一条都探不到、而这部片子又是日本片（有番号）时，顺手让服务端抓一次：
  /// 服务端按番号去字幕站抓 .srt 写到片源旁边，抓完再探一次。
  /// 这样「哪些片子需要下字幕、哪些压根没有字幕」在弹窗里就能看清楚。
  Future<void> _probeSubtitles({bool allowFetch = true}) async {
    try {
      final res = await ApiSession.instance.client
          .videoSubtitles(id: widget.item.id)
          .timeout(const Duration(seconds: 10));
      var embedded = 0;
      var external = 0;
      for (final sub in res.items) {
        if (sub.name.startsWith('#embedded:')) {
          embedded += 1;
        } else {
          external += 1;
        }
      }
      if (!mounted) return;
      setState(() {
        _subEmbedded = embedded;
        _subExternal = external;
        _subChecked = true;
        if (_subtitleTouched) return;
        // 有文本内嵌轨就内挂（播放器直接能开）；只有外挂字幕就外挂。
        _subtitleMode = embedded > 0
            ? 'embed'
            : (external > 0 ? 'external' : 'none');
      });
      if (!_subtitleTouched) _scheduleQuote();
      if (embedded == 0 && external == 0 && allowFetch && _canFetchSubtitle) {
        await _fetchSubtitleAndReprobe();
      }
    } catch (_) {
      if (!mounted) return;
      // 探测失败（源离线 / ffprobe 慢）不该挡住下载：保持默认，不提示。
      setState(() => _subChecked = true);
    }
  }

  /// 有番号 = 日本片：服务端能按番号去字幕站抓外挂字幕。
  bool get _canFetchSubtitle => (widget.item.code ?? '').trim().isNotEmpty;

  Future<void> _fetchSubtitleAndReprobe() async {
    try {
      await ApiSession.instance.client.videoSubtitleFetch(body: <String, dynamic>{
        'id': widget.item.id,
      });
    } catch (_) {
      // 没权限 / 网络失败：抓不到就算了，不该挡住下载
      return;
    }
    // 抓取是异步的（服务端立刻返回，抓在后台跑），等一会儿再探一次。
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    await _probeSubtitles(allowFetch: false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _kbps.dispose();
    super.dispose();
  }

  void _scheduleQuote() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _quoteNow);
  }

  Future<void> _quoteNow() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.offlineQuote(
        body: OfflineQuoteBody(
          itemId: widget.item.id,
          codec: _codec,
          height: _height,
          qualityMode: _quality,
          subtitleMode: _subtitleMode,
          videoKbps: _manualKbps ? (int.tryParse(_kbps.text.trim()) ?? 0) : null,
        ),
      );
      if (!mounted) return;
      setState(() {
        _quote = res;
        // 服务端收敛后的真实档位反过来校准界面（片源矮时 1080P 会变 720P）
        final target = res.target;
        _codec = '${target['codec'] ?? _codec}';
        _height = (target['height'] as num?)?.toInt() ?? _height;
        if (!_manualKbps) {
          _kbps.text = '${(target['videoKbps'] as num?)?.toInt() ?? 0}';
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        // 旧 quote 的预估体积是上一组参数的，留着会让人以为「改了没变」。
        _quote = null;
        _loading = false;
      });
    }
  }

  List<int> get _heights {
    final raw = (_quote?.capabilities['heights'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => (e as num).toInt())
        .toList();
    return raw;
  }

  String _codecLabel(String key) {
    if (key == 'original') return tr('video.offline.original');
    return playCodecOf(key)?.label ?? key;
  }

  String _specText(Map<String, dynamic> target) {
    final codec = '${target['codec'] ?? ''}';
    final height = (target['height'] as num?)?.toInt() ?? 0;
    final kbps = (target['videoKbps'] as num?)?.toInt() ?? 0;
    if (codec == 'original') return tr('video.offline.original');
    final heightText = height > 0 ? '${height}P' : '—';
    final codecText = _codecLabel(codec);
    final kbpsText = kbps > 0 ? '$kbps ${tr('video.offline.bitrateUnit')}' : '—';
    return tr('video.offline.spec', {
      'height': heightText,
      'codec': codecText,
      'kbps': kbpsText,
    });
  }

  Future<void> _submit() async {
    final quote = _quote;
    if (quote == null || _submitting) return;

    // 已下载过同一部片：先问一句再覆盖（需求书 §3.2 场景 A）
    final existing = widget.existing;
    if (existing != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('video.offline.replaceTitle')),
          content: Text(
            tr('video.offline.replaceBody', {
              'old': existing.specLabel.isEmpty ? existing.container : existing.specLabel,
              'new': _specText(quote.target),
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('video.offline.replaceConfirm')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _submitting = true);
    try {
      final target = quote.target;
      final spec = OfflineSpec(
        preset: '${target['preset'] ?? 'custom'}',
        codec: '${target['codec'] ?? 'h265'}',
        height: (target['height'] as num?)?.toInt() ?? 0,
        videoKbps: (target['videoKbps'] as num?)?.toInt() ?? 0,
        audioKbps: (target['audioKbps'] as num?)?.toInt() ?? 128,
        audioIndex: (target['audioIndex'] as num?)?.toInt() ?? 0,
        container: '${target['container'] ?? 'mp4'}',
        subtitleMode: '${target['subtitleMode'] ?? 'none'}',
      );
      // 右键菜单进来的调用方不带剧名：用条目自己的 `series` 兜底，
      // 否则整剧卡片会以「第 3 集」为标题。
      final seriesName = (widget.seriesTitle ?? widget.item.series ?? '').trim();
      final hasSeries = seriesName.isNotEmpty;
      await OfflineDownloadManager.instance.start(
        OfflineRequest(
          itemId: widget.item.id,
          libraryId: widget.item.libraryId,
          libraryName: widget.libraryName,
          title: hasSeries ? '$seriesName · ${_episodeLabel()}' : widget.item.title,
          spec: spec,
          seriesKey: _seriesKey(),
          seriesTitle: hasSeries ? seriesName : null,
          season: widget.item.season,
          episode: widget.item.episode,
          totalEpisodes: widget.totalEpisodes ?? (widget.item.seriesInfo?.episodes ?? 0),
          posterUrl: _posterUrl(series: hasSeries),
          fallbackPosterUrl: videoPosterUrl(widget.item),
          replace: existing != null,
          // 「外挂」在服务端等同于「不内挂」（产物字节完全一样，共用同一份缓存），
          // 额外动作在客户端：下完再抓字幕文件。
          // 选了内挂但这部片子**没有文本内嵌轨**（只有图形字幕）时也抓外挂兜底，
          // 否则下载完的片子等于没字幕。
          fetchSubtitles:
              _subtitleMode == 'external' ||
              (_subtitleMode == 'embed' && _subChecked && _subEmbedded == 0),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      _toast(context, tr('video.offline.downloading'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }

  String _episodeLabel() {
    final ep = widget.item.episode ?? 0;
    if (ep <= 0) return widget.item.title;
    return tr('video.offline.episodeLabel', {'n': '$ep'});
  }

  /// 剧集聚合键：与服务端同口径（libraryId + \u0000 + series）
  String? _seriesKey() {
    final series = (widget.item.series ?? '').trim();
    if (series.isEmpty) return null;
    return '${widget.item.libraryId}\u0000$series';
  }

  /// 剧集用整剧封面（`seriesInfo.coverId` 指向代表集），电影用本片海报
  String? _posterUrl({required bool series}) {
    final base = ApiSession.instance.baseUrl;
    if (series) {
      final cover = widget.item.seriesInfo?.coverId;
      if (cover != null && cover.isNotEmpty) {
        return '$base/api/v1/video/art?id=${Uri.encodeComponent(cover)}&size=800';
      }
    }
    return videoPosterUrl(widget.item, size: 800);
  }

  @override
  Widget build(BuildContext context) {
    final quote = _quote;
    final source = quote?.source;
    final target = quote?.target;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('video.offline.dialogTitle'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NasTokens.fontBody, color: context.nasTextSecondary),
          ),
          const SizedBox(height: 12),
          if (source != null) _sourceLine(source),
          const SizedBox(height: 16),

          _codecField(),
          const SizedBox(height: 10),
          if (_codec != 'original') ...[
            _heightField(),
            const SizedBox(height: 10),
            _qualityField(),
            const SizedBox(height: 10),
            _bitrateField(quote),
          ] else
            Text(
              tr('video.offline.originalHint'),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
          const SizedBox(height: 6),
          _subtitleField(),
          _subtitleHint(),

          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('video.offline.estimated'),
                    style: const TextStyle(fontSize: NasTokens.fontBody),
                  ),
                ),
                Text(
                  quote == null
                      ? '—'
                      : formatBytes((quote.estimate['bytes'] as num?)?.toInt() ?? 0),
                  style: const TextStyle(
                    fontSize: NasTokens.fontTitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (target != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _specText(target),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                child: Text(tr('common.cancel')),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (_loading || _submitting || quote == null) ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download, size: 18),
                label: Text(tr('video.offline.start')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sourceLine(Map<String, dynamic> source) {
    final width = (source['width'] as num?)?.toInt() ?? 0;
    final height = (source['height'] as num?)?.toInt() ?? 0;
    final codec = '${source['videoCodec'] ?? ''}';
    final duration = (source['durationMs'] as num?)?.toInt() ?? 0;
    final bytes = (source['bytes'] as num?)?.toInt() ?? 0;
    final parts = <String>[
      if (width > 0 && height > 0) '$width×$height',
      if (codec.isNotEmpty) codec.toUpperCase(),
      if (duration > 0) _durationText(duration),
      if (bytes > 0) formatBytes(bytes),
    ];
    return Text(
      '${tr('video.offline.sourceInfo')}：${parts.join(' · ')}',
      style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
    );
  }

  static String _durationText(int ms) {
    final total = (ms / 1000).round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  Widget _codecField() {
    final codecs = <String>['original', ...playableCodecs().map((c) => c.key)];
    return NasDropdown<String>(
      initialValue: _codec,
      decoration: InputDecoration(labelText: tr('video.offline.codec')),
      items: [
        for (final key in codecs)
          DropdownMenuItem(value: key, child: Text(_codecLabel(key))),
      ],
      onChanged: (v) {
        if (v == null || v == _codec) return;
        setState(() {
          _codec = v;
          if (v == 'original') {
            _height = 0;
            // 原画不重编码：内挂没有意义（字幕本来就在 mkv 里），退成「不」
            if (_subtitleMode == 'embed') _subtitleMode = 'none';
          }
        });
        _scheduleQuote();
      },
    );
  }

  Widget _heightField() {
    final heights = _heights;
    return NasDropdown<int>(
      initialValue: heights.contains(_height) ? _height : (heights.isEmpty ? null : heights.first),
      decoration: InputDecoration(labelText: tr('video.offline.resolution')),
      items: [
        for (final h in heights)
          DropdownMenuItem(value: h, child: Text('${h}P')),
      ],
      onChanged: (v) {
        if (v == null || v == _height) return;
        setState(() => _height = v);
        _scheduleQuote();
      },
    );
  }

  Widget _qualityField() {
    const keys = <String>['saver', 'standard', 'high'];
    String label(String k) {
      switch (k) {
        case 'saver':
          return tr('video.offline.qualitySaver');
        case 'high':
          return tr('video.offline.qualityHigh');
        default:
          return tr('video.offline.qualityStandard');
      }
    }

    return NasDropdown<String>(
      initialValue: _quality,
      decoration: InputDecoration(labelText: tr('video.offline.quality')),
      items: [
        for (final k in keys) DropdownMenuItem(value: k, child: Text(label(k))),
      ],
      onChanged: (v) {
        if (v == null || v == _quality) return;
        setState(() => _quality = v);
        _scheduleQuote();
      },
    );
  }

  /// 字幕三选一：
  ///   · 内挂：`-c:s mov_text` 写进 mp4（只有转码档有；原画的字幕本来就在 mkv 里）；
  ///   · 外挂：视频不带字幕，另外把 srt / ass 转成 WebVTT 存到 `subtitles/`，
  ///     播放时可以切（多语言字幕必须走这条）；
  ///   · 不：完全不要。
  /// 烧录（把字幕压进画面）不做：要重编码一遍视频，画质和体积都吃亏。
  Widget _subtitleField() {
    final original = _codec == 'original';
    final modes = <String>[if (!original) 'embed', 'none', 'external'];
    String labelOf(String mode) {
      switch (mode) {
        case 'embed':
          final base = tr('video.offline.subtitleEmbed');
          return _subChecked ? '$base（$_subEmbedded）' : base;
        case 'external':
          final base = tr('video.offline.subtitleExternal');
          return _subChecked ? '$base（$_subExternal）' : base;
        default:
          return tr('video.offline.subtitleNone');
      }
    }

    return NasDropdown<String>(
      initialValue: modes.contains(_subtitleMode) ? _subtitleMode : 'none',
      decoration: InputDecoration(labelText: tr('video.offline.subtitle')),
      items: [
        for (final mode in modes)
          DropdownMenuItem(value: mode, child: Text(labelOf(mode))),
      ],
      onChanged: (v) {
        if (v == null || v == _subtitleMode) return;
        setState(() {
          _subtitleMode = v;
          _subtitleTouched = true;
        });
        _scheduleQuote();
      },
    );
  }

  /// 字幕可用性提示：让用户一眼看出「这部片子有没有字幕可下」。
  Widget _subtitleHint() {
    if (!_subChecked) return const SizedBox.shrink();
    final none = _subEmbedded == 0 && _subExternal == 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        none
            ? tr('video.offline.subtitleNoneFound')
            : tr('video.offline.subtitleCounts', {
                'embedded': '$_subEmbedded',
                'external': '$_subExternal',
              }),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: none
              ? Theme.of(context).colorScheme.error
              : context.nasTextSecondary,
        ),
      ),
    );
  }

  Widget _bitrateField(OfflineQuoteResponse? quote) {
    final limits = quote?.limits;
    final minKbps = (limits?['minKbps'] as num?)?.toInt() ?? 0;
    final maxKbps = (limits?['maxKbps'] as num?)?.toInt() ?? 0;
    final recommended = (limits?['recommendedKbps'] as num?)?.toInt() ?? 0;
    return TextField(
      controller: _kbps,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: tr('video.offline.bitrate'),
        suffixText: tr('video.offline.bitrateUnit'),
        helperText: maxKbps > 0 ? '$recommended ｜ $minKbps ~ $maxKbps' : null,
      ),
      onChanged: (v) {
        final manual = v.trim().isNotEmpty;
        if (manual == _manualKbps) return;
        setState(() => _manualKbps = manual);
        if (manual) _scheduleQuote();
      },
    );
  }
}
