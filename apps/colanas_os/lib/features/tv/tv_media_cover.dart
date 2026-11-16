import 'package:flutter/material.dart';

import '../video/video_card.dart' show videoArtHeaders;

/// TV 端通用封面：按顺序尝试多级图片地址，全部失败时用「名称哈希渐变 + 文字」
/// 生成海报，杜绝黑底数字方块 / 纯灰占位。
///
/// 地址顺序一般就是：本地/刮削海报 → 服务端抽帧 → 空。
class TvMediaCover extends StatefulWidget {
  const TvMediaCover({
    super.key,
    required this.urls,
    required this.fallbackText,
    this.icon = Icons.video_library_outlined,
    this.cacheWidth,
    this.borderRadius = 0,
    this.fit = BoxFit.cover,
    this.headers,
  });

  /// 依次尝试的图片地址（null / 空串会被跳过）。
  final List<String?> urls;
  final String fallbackText;
  final IconData icon;
  final int? cacheWidth;
  final double borderRadius;
  final BoxFit fit;
  final Map<String, String>? headers;

  @override
  State<TvMediaCover> createState() => _TvMediaCoverState();
}

class _TvMediaCoverState extends State<TvMediaCover> {
  int _fails = 0;

  List<String> get _candidates => <String>[
    for (final url in widget.urls)
      if ((url ?? '').trim().isNotEmpty) url!,
  ];

  @override
  void didUpdateWidget(TvMediaCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameUrls(oldWidget.urls, widget.urls)) _fails = 0;
  }

  static bool _sameUrls(List<String?> a, List<String?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final urls = _candidates;
    final Widget child;
    if (urls.isEmpty || _fails >= urls.length) {
      child = _TvCoverPlaceholder(
        text: widget.fallbackText,
        icon: widget.icon,
      );
    } else {
      child = Image.network(
        urls[_fails],
        key: ValueKey<String>(urls[_fails]),
        fit: widget.fit,
        headers: widget.headers ?? videoArtHeaders,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (context, _, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _fails += 1);
          });
          return _TvCoverPlaceholder(
            text: widget.fallbackText,
            icon: widget.icon,
          );
        },
      );
    }
    if (widget.borderRadius <= 0) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: child,
    );
  }
}

class _TvCoverPlaceholder extends StatelessWidget {
  const _TvCoverPlaceholder({required this.text, required this.icon});

  final String text;
  final IconData icon;

  static const List<List<Color>> _palettes = <List<Color>>[
    <Color>[Color(0xFF2B2450), Color(0xFF6C5CE7)],
    <Color>[Color(0xFF11343A), Color(0xFF00B894)],
    <Color>[Color(0xFF102A45), Color(0xFF0984E3)],
    <Color>[Color(0xFF43221A), Color(0xFFE17055)],
    <Color>[Color(0xFF47161A), Color(0xFFD63031)],
    <Color>[Color(0xFF45142C), Color(0xFFE84393)],
    <Color>[Color(0xFF3C2F0E), Color(0xFFFDCB6E)],
  ];

  @override
  Widget build(BuildContext context) {
    final seed = text.isEmpty ? 'media' : text;
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final palette = _palettes[hash % _palettes.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: Colors.white.withValues(alpha: 0.72)),
            const SizedBox(height: 8),
            Flexible(
              child: Text(
                text,
                maxLines: 3,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
