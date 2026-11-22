import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

class TvMedia3State {
  const TvMedia3State({
    this.positionMs = 0,
    this.durationMs = 0,
    this.bufferedPositionMs = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
    this.videoDecoder = '',
    this.firstFrameMs,
    this.viewWidth = 0,
    this.viewHeight = 0,
    this.surfaceWidth = 0,
    this.surfaceHeight = 0,

    /// 当前流里没有任何可用的音频解码器（手机上的 E-AC3 / DTS-HD 很常见）
    this.audioUnsupported = false,
    this.error,
  });

  final int positionMs;
  final int durationMs;
  final int bufferedPositionMs;
  final int videoWidth;
  final int videoHeight;
  final bool isPlaying;
  final bool isBuffering;
  final bool isCompleted;
  final String videoDecoder;
  final int? firstFrameMs;

  /// 原生 PlayerView 与内部 SurfaceView 的真实像素尺寸，排障用。
  final int viewWidth;
  final int viewHeight;
  final int surfaceWidth;
  final int surfaceHeight;

  /// 当前流里没有可用的音频解码器（手机 E-AC3 / DTS-HD）
  final bool audioUnsupported;

  final String? error;

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);
  Duration get bufferedPosition => Duration(milliseconds: bufferedPositionMs);
  Duration get buffer {
    final aheadMs = bufferedPositionMs - positionMs;
    return Duration(milliseconds: aheadMs > 0 ? aheadMs : 0);
  }

  factory TvMedia3State.fromMap(Map<Object?, Object?> map) => TvMedia3State(
    positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    bufferedPositionMs: (map['bufferedPositionMs'] as num?)?.toInt() ?? 0,
    videoWidth: (map['videoWidth'] as num?)?.toInt() ?? 0,
    videoHeight: (map['videoHeight'] as num?)?.toInt() ?? 0,
    isPlaying: map['isPlaying'] == true,
    isBuffering: map['isBuffering'] == true,
    isCompleted: map['isCompleted'] == true,
    videoDecoder: map['videoDecoder']?.toString() ?? '',
    firstFrameMs: (map['firstFrameMs'] as num?)?.toInt(),
    viewWidth: (map['viewWidth'] as num?)?.toInt() ?? 0,
    viewHeight: (map['viewHeight'] as num?)?.toInt() ?? 0,
    surfaceWidth: (map['surfaceWidth'] as num?)?.toInt() ?? 0,
    surfaceHeight: (map['surfaceHeight'] as num?)?.toInt() ?? 0,
    audioUnsupported: map['audioUnsupported'] == true,
    error: map['error']?.toString(),
  );
}

/// 原生视频播放器控制器。
///
/// 视频画面不再由 Flutter 平台视图提供：原生层把 `PlayerView`（裸 SurfaceView）
/// 插到 Activity 内容层最底部，Flutter 用透明像素把它露出来。所以这里只负责
/// 「挂上 / 摘下原生层」和发控制命令、收状态事件。
class TvMedia3PlayerController {
  /// 原生 PlatformView 的注册名，与 `TvVideoViewFactory.VIEW_TYPE`（Kotlin）一致。
  static const String viewType = 'colanasos.tv_media3_view';

  static const _methodChannel = MethodChannel('com.colanas.os/tv_media3');
  static const _eventChannel = EventChannel('com.colanas.os/tv_media3/events');

  final _stateChanges = StreamController<TvMedia3State>.broadcast();
  TvMedia3State _state = const TvMedia3State();
  StreamSubscription<dynamic>? _eventSubscription;
  bool _disposed = false;
  bool _attached = false;
  Map<String, Object?>? _lastOpen;

  TvMedia3State get state => _state;
  Stream<TvMedia3State> get states => _stateChanges.stream;
  late final Stream<Duration> positionStream = states
      .map((state) => state.position)
      .distinct();
  late final Stream<Duration> durationStream = states
      .map((state) => state.duration)
      .distinct();
  late final Stream<bool> playingStream = states
      .map((state) => state.isPlaying)
      .distinct();
  late final Stream<bool> bufferingStream = states
      .map((state) => state.isBuffering)
      .distinct();
  late final Stream<bool> completedStream = states
      .map((state) => state.isCompleted)
      .distinct();
  late final Stream<String> errorStream = states
      .map((state) => state.error)
      .where((error) => error != null && error.isNotEmpty)
      .cast<String>();

  TvMedia3PlayerController() {
    // 只有 Android 装了原生视频通道。桌面 / Web 监听会拿到 MissingPluginException，
    // 反而把播放页顶成错误页，所以这里直接不订阅。
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          _update(TvMedia3State.fromMap(Map<Object?, Object?>.from(event)));
        }
      },
      onError: (Object error) {
        _update(
          TvMedia3State(error: 'Native video event channel failed: $error'),
        );
      },
    );
  }

  static Future<bool> supportsDolbyVision() async {
    try {
      return await _methodChannel.invokeMethod<bool>('supportsDolbyVision') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// 让原生层把视频 Surface 挂到 Flutter 下面。
  Future<void> attach() async {
    if (_disposed || _attached) return;
    _attached = true;
    try {
      await _methodChannel.invokeMethod<void>('attach');
    } on PlatformException {
      _attached = false;
    }
  }

  /// 从窗口里摘下原生视频层（离开播放页时调用）。
  Future<void> detach() async {
    if (!_attached) return;
    _attached = false;
    try {
      await _methodChannel.invokeMethod<void>('detach');
    } on PlatformException {
      // 原生层可能已经随 Activity 一起销毁，忽略
    }
  }

  Future<void> open({
    required String url,
    required int positionMs,
    required bool play,
    required String formatHint,

    /// 隧道模式：只有电视芯片支持。手机 / 平板打开会黑屏（解码器就绪但
    /// VideoSize 停在 0x0，只有声音），所以默认关，由 TV 模式显式打开。
    bool tunneled = false,

    /// 视频与音频分开取：视频用 [url]（原片，杜比视界配置完整），音频用这条
    /// 服务端转好的 AAC 流。
    String? audioUrl,

    /// 媒体通知 / 状态栏显示的标题
    String? title,
  }) async {
    if (_disposed) throw StateError('TV Media3 player is disposed');
    final args = <String, Object?>{
      'url': url,
      'positionMs': positionMs < 0 ? 0 : positionMs,
      'play': play,
      'formatHint': formatHint,
      'tunneled': tunneled,
      if (audioUrl != null && audioUrl.isNotEmpty) 'audioUrl': audioUrl,
      if (title != null && title.isNotEmpty) 'title': title,
    };
    _lastOpen = args;
    _update(const TvMedia3State(isBuffering: true));
    await _methodChannel.invokeMethod<void>('open', args);
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  Future<void> seekTo(Duration position) =>
      _invoke('seekTo', {'positionMs': position.inMilliseconds});
  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume.clamp(0, 100) / 100});
  Future<void> setRate(double rate) =>
      _invoke('setRate', {'rate': rate.clamp(0.5, 2.0)});

  Future<void> setAudioTrack(int index) =>
      _invoke('setAudioTrack', {'index': index});
  Future<void> setRepeatMode(String mode) =>
      _invoke('setRepeatMode', {'mode': mode});
  Future<void> setShuffle(bool enabled) =>
      _invoke('setShuffle', {'enabled': enabled});

  Future<void> stop() async {
    if (_disposed) return;
    _lastOpen = null;
    try {
      await _methodChannel.invokeMethod<void>('stop');
    } on PlatformException {
      // 播放器还没建出来：没有可停的东西
    }
    _update(const TvMedia3State());
  }

  /// 位置：重新打开（换档 / 续播）时用上一次的源与播放意图。
  Map<String, Object?>? get lastOpen => _lastOpen;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    if (!_supported) {
      await _stateChanges.close();
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('dispose');
    } on PlatformException {
      // Activity 已销毁：原生层随之释放
    } on MissingPluginException {
      // 原生通道不存在（极少数桌面 / 测试环境）
    }
    await _stateChanges.close();
  }

  Future<void> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_disposed) throw StateError('TV Media3 player is disposed');
    await _methodChannel.invokeMethod<void>(method, args);
  }

  void _update(TvMedia3State state) {
    if (_disposed) return;
    _state = state;
    _stateChanges.add(state);
  }
}

/// 视频画面：PlatformView（Hybrid Composition）。
///
/// 用 `PlatformViewLink` + `AndroidViewSurface`，把原生 PlayerView（内部是裸
/// SurfaceView）作为**窗口内**的一块真实 Surface 嵌进 Flutter 视图树。
///
/// 为什么不用「垫在整窗底部的 SurfaceView」：那条路要求整窗透明，透明窗口里的
/// 视频层拿不到独占的 HDR 合成通道，杜比视界（IPT-PQ）会被当 SDR 混合 ——
/// 徽章显示 HDR / DV 已激活，画面却是紫的（1.3.31 电视实测）。
/// 窗口内 Surface + 不透明窗口，HDR 元数据才能一路到显示端。
class TvMedia3PlayerSurface extends StatefulWidget {
  const TvMedia3PlayerSurface({
    required this.controller,
    this.onTap,
    this.onAttached,
    super.key,
  });

  final TvMedia3PlayerController controller;
  final VoidCallback? onTap;

  /// 原生视图创建完成后的回调（播放页用来收掉「准备中」那层黑底）。
  final VoidCallback? onAttached;

  @override
  State<TvMedia3PlayerSurface> createState() => _TvMedia3PlayerSurfaceState();
}

class _TvMedia3PlayerSurfaceState extends State<TvMedia3PlayerSurface> {
  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PlatformViewLink(
          viewType: TvMedia3PlayerController.viewType,
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          ),
          onCreatePlatformView: (params) {
            final controller = PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: TvMedia3PlayerController.viewType,
              layoutDirection: Directionality.of(context),
              creationParams: const <String, Object?>{},
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            );
            controller.addOnPlatformViewCreatedListener((_) {
              if (mounted) widget.onAttached?.call();
            });
            controller.create();
            return controller;
          },
        ),
        if (widget.onTap != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onTap,
            ),
          ),
      ],
    );
  }
}

