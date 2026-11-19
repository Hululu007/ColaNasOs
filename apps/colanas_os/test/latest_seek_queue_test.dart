import 'dart:async';

import 'package:colanas_os/core/latest_seek_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes seeks and keeps only the newest queued target', () async {
    final errors = <Object>[];
    final queue = LatestSeekQueue(onError: (error, _) => errors.add(error));
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final applied = <int>[];

    final first = queue.enqueue(() async {
      applied.add(1);
      firstStarted.complete();
      await releaseFirst.future;
    });
    await firstStarted.future;

    final second = queue.enqueue(() async => applied.add(2));
    final third = queue.enqueue(() async => applied.add(3));
    releaseFirst.complete();
    await Future.wait([first, second, third]);

    expect(applied, [1, 3]);
    expect(errors, isEmpty);
  });

  test('invalidated queued seek cannot affect a newly opened stream', () async {
    final queue = LatestSeekQueue(onError: (_, _) {});
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final applied = <String>[];

    final first = queue.enqueue(() async {
      applied.add('old-active');
      firstStarted.complete();
      await releaseFirst.future;
    });
    await firstStarted.future;

    final queued = queue.enqueue(() async => applied.add('old-queued'));
    queue.invalidate();
    final current = queue.enqueue(() async => applied.add('current'));
    releaseFirst.complete();
    await Future.wait([first, queued, current]);

    expect(applied, ['old-active', 'current']);
  });
}
