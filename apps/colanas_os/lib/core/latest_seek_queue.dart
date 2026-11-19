/// Serializes player seek commands and skips queued commands superseded by newer input.
class LatestSeekQueue {
  LatestSeekQueue({required this.onError});

  final void Function(Object error, StackTrace stackTrace) onError;

  Future<void> _tail = Future<void>.value();
  int _generation = 0;

  void invalidate() {
    _generation += 1;
  }

  Future<bool> enqueue(Future<void> Function() seek) {
    final generation = ++_generation;
    var executed = false;
    final operation = _tail.then((_) async {
      if (generation != _generation) return;
      executed = true;
      await seek();
    });
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        onError(error, stackTrace);
      },
    );
    return operation.then((_) => executed);
  }
}
