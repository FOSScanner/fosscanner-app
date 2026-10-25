import 'dart:async';

/// Serializes OpenCV workers owned by one scanner session.
///
/// A route may be disposed before its worker finishes, so every editor opened
/// by the same home screen must share this queue.
class ImageProcessingQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() work) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await work());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
