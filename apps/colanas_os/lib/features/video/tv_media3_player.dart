import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    error: map['error']?.toString(),
  );
}

class TvMedia3PlayerController {
  static const _methodChannel = MethodChannel('com.colanas.os/tv_media3');
  static const _viewType = 'colanasos.tv_media3';

  final _stateChanges = StreamController<TvMedia3State>.broadcast();
  Completer<int>? _viewReady;
  TvMedia3State _state = const TvMedia3State();
  StreamSubscription<dynamic>? _eventSubscription;
  int? _viewId;
  bool _disposed = false;
  bool _playWhenReady = true;
  Map<String, Object?>? _pendingOpen;
  Map<String, Object?>? _lastOpen;
  bool _hasAttached = false;

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

  static Future<bool> supportsDolbyVision() async {
    try {
      return await _methodChannel.invokeMethod<bool>('supportsDolbyVision') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> attach(int viewId) async {
    if (_disposed) return;
    final previousViewId = _viewId;
    _viewId = viewId;
    if (previousViewId != viewId && _viewReady?.isCompleted == true) {
      _viewReady = null;
    }
    _eventSubscription?.cancel();
    _eventSubscription = EventChannel('com.colanas.os/tv_media3/events/$viewId')
        .receiveBroadcastStream()
        .listen(
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
    final ready = _viewReady;
    if (ready != null && !ready.isCompleted) ready.complete(viewId);
    final pending = _pendingOpen ?? (_hasAttached ? _lastOpen : null);
    if (pending != null) {
      _pendingOpen = null;
      try {
        await _invoke('open', pending);
      } on PlatformException catch (error) {
        _update(TvMedia3State(error: error.message ?? error.code));
      } on StateError {
        if (!_disposed) rethrow;
      }
    }
    _hasAttached = true;
  }

  void detach(int viewId) {
    if (_viewId != viewId) return;
    final lastOpen = _lastOpen;
    if (lastOpen != null) {
      _lastOpen = {
        ...lastOpen,
        'positionMs': _state.positionMs,
        'play': _playWhenReady,
      };
    }
    _viewId = null;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    final ready = _viewReady;
    if (ready != null && ready.isCompleted) _viewReady = null;
  }

  Future<void> open({
    required String url,
    required int positionMs,
    required bool play,
    required String formatHint,
  }) async {
    if (_disposed) throw StateError('TV Media3 player is disposed');
    final args = <String, Object?>{
      'url': url,
      'positionMs': positionMs < 0 ? 0 : positionMs,
      'play': play,
      'formatHint': formatHint,
    };
    _playWhenReady = play;
    _lastOpen = args;
    _update(const TvMedia3State(isBuffering: true));
    if (_viewId == null) {
      _pendingOpen = args;
      return;
    }
    await _invoke('open', args);
  }

  Future<void> play() {
    _playWhenReady = true;
    return _invoke('play');
  }

  Future<void> pause() {
    _playWhenReady = false;
    return _invoke('pause');
  }

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
    final viewId = _viewId;
    if (viewId != null) {
      await _invoke('stop');
    } else {
      final ready = _viewReady;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(
          StateError('TV Media3 player stopped before attach'),
        );
      }
      _viewReady = null;
    }
    _pendingOpen = null;
    _lastOpen = null;
    _playWhenReady = false;
    _update(const TvMedia3State());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final ready = _viewReady;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('TV Media3 player is disposed'));
    }
    _viewReady = null;
    _pendingOpen = null;
    _lastOpen = null;
    final viewId = _viewId;
    _viewId = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    if (viewId != null) {
      try {
        await _methodChannel.invokeMethod<void>('dispose', {'viewId': viewId});
      } on PlatformException {
        // The native view may already have released its player.
      }
    }
    await _stateChanges.close();
  }

  Future<void> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    while (true) {
      if (_disposed) throw StateError('TV Media3 player is disposed');
      final viewId = _viewId;
      final id =
          viewId ??
          await (_viewReady ??= Completer<int>()).future.timeout(
            const Duration(seconds: 15),
          );
      if (_disposed) throw StateError('TV Media3 player is disposed');
      if (_viewId != id) continue;
      await _methodChannel.invokeMethod<void>(method, {'viewId': id, ...args});
      return;
    }
  }

  void _update(TvMedia3State state) {
    if (_disposed) return;
    _state = state;
    _stateChanges.add(state);
  }
}

class TvMedia3PlayerSurface extends StatefulWidget {
  const TvMedia3PlayerSurface({
    required this.controller,
    this.onTap,
    super.key,
  });

  final TvMedia3PlayerController controller;
  final VoidCallback? onTap;

  @override
  State<TvMedia3PlayerSurface> createState() => _TvMedia3PlayerSurfaceState();
}

class _TvMedia3PlayerSurfaceState extends State<TvMedia3PlayerSurface> {
  int? _viewId;

  @override
  void didUpdateWidget(covariant TvMedia3PlayerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller && _viewId != null) {
      oldWidget.controller.detach(_viewId!);
      _viewId = null;
    }
  }

  @override
  void dispose() {
    final viewId = _viewId;
    if (viewId != null) widget.controller.detach(viewId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        AndroidView(
          viewType: TvMedia3PlayerController._viewType,
          creationParams: const <String, Object?>{},
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: (id) {
            _viewId = id;
            unawaited(widget.controller.attach(id));
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
