import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/image_processing_queue.dart';

void main() {
  test('idle waits for all previously submitted work', () async {
    final queue = ImageProcessingQueue();
    final first = Completer<void>();
    final second = Completer<void>();
    final started = <int>[];
    final firstWork = queue.run(() async {
      started.add(1);
      await first.future;
    });
    final secondWork = queue.run(() async {
      started.add(2);
      await second.future;
    });
    var idle = false;
    final drained = queue.idle.then((_) => idle = true);
    await Future<void>.delayed(Duration.zero);
    expect(started, [1]);
    expect(idle, isFalse);
    first.complete();
    await firstWork;
    await Future<void>.delayed(Duration.zero);
    expect(started, [1, 2]);
    expect(idle, isFalse);
    second.complete();
    await secondWork;
    await drained;
    expect(idle, isTrue);
  });

  test('a failed worker does not poison idle or subsequent jobs', () async {
    final queue = ImageProcessingQueue();
    final failed = queue.run<void>(() async => throw StateError('injected'));
    await expectLater(failed, throwsStateError);
    await queue.idle;
    expect(await queue.run(() async => 42), 42);
  });
}
