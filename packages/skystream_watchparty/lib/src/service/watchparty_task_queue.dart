import 'dart:async';

/// Single-threaded sequential task queue (WhatsApp/Discord event loop pattern).
/// Ensures that message state mutations, outbox flushes, ACKs, and history sync
/// execute sequentially in strict order without race conditions.
class WatchPartyTaskQueue {
  Future<void> _lastTask = Future.value();
  bool _isDisposed = false;

  /// Enqueues an async task to execute sequentially after all previous tasks complete.
  Future<T> enqueue<T>(Future<T> Function() task) {
    if (_isDisposed) {
      return Future.error(StateError('WatchPartyTaskQueue is disposed'));
    }

    final completer = Completer<T>();
    _lastTask = _lastTask.then((_) async {
      if (_isDisposed) return;
      try {
        final result = await task();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }).catchError((_) {});

    return completer.future;
  }

  void dispose() {
    _isDisposed = true;
  }
}
