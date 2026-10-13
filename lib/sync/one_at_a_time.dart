import 'dart:async';

/// Runs jobs one at a time: a job asked for while another runs waits for it.
///
/// The marker of the running job completes only after it has been cleared.
/// That ordering is the whole point. Sync once marked a run with the engine's
/// own future, which finished while the run was still saving its results; a
/// waiter then awaited that finished future again and again. Awaiting a
/// finished future is a microtask, so the loop never let the event queue run,
/// the save it was waiting for never landed, and the app froze on a blank
/// screen.
class OneAtATime {
  Future<void>? _running;

  /// A job is running, or about to.
  bool get busy => _running != null;

  Future<T> run<T>(Future<T> Function() job) async {
    while (_running != null) {
      await _running;
    }
    final done = Completer<void>();
    _running = done.future;
    try {
      return await job();
    } finally {
      _running = null;
      done.complete();
    }
  }
}
