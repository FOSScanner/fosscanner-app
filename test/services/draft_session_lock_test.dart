import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/draft_store_native.dart';
import 'package:fosscanner/services/draft_session.dart';

class _LockProcess {
  _LockProcess(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ) {
    process.stderr.transform(utf8.decoder).listen(errors.write);
  }

  final Process process;
  final StreamIterator<String> lines;
  final errors = StringBuffer();

  Future<String> acquire() async {
    process.stdin.writeln('acquire');
    expect(
      await lines.moveNext().timeout(const Duration(seconds: 15)),
      isTrue,
      reason: errors.toString(),
    );
    return lines.current;
  }
}

void main() {
  late Directory directory;
  final processes = <_LockProcess>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fos-session-lock-');
  });
  tearDown(() async {
    for (final child in processes) {
      child.process.kill();
      await child.process.exitCode;
      await child.lines.cancel();
    }
    processes.clear();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<_LockProcess> start([String? root]) async {
    final process = await Process.start('dart', [
      'test/fixtures/draft_lock_process.dart',
      root ?? directory.path,
    ]);
    final child = _LockProcess(process);
    processes.add(child);
    return child;
  }

  for (final abrupt in [false, true]) {
    test(
      'another process retries after ${abrupt ? 'SIGKILL' : 'normal exit'}',
      () async {
        final holder = await start();
        final contender = await start();
        expect(await holder.acquire(), 'acquired');
        expect(
          await holder.acquire(),
          'acquired',
          reason: 'same owner is idempotent',
        );
        expect(await contender.acquire(), 'busy');
        if (abrupt) {
          holder.process.kill(ProcessSignal.sigkill);
        } else {
          holder.process.stdin.writeln('quit');
        }
        await holder.process.exitCode;
        expect(await contender.acquire(), 'acquired');
      },
    );
  }

  test('storage failures remain distinguishable and can be retried', () async {
    final occupied = File('${directory.path}/not-a-directory');
    await occupied.writeAsString('occupied');
    final child = await start(occupied.path);
    expect(await child.acquire(), 'storage-error');
    await occupied.delete();
    expect(await child.acquire(), 'acquired');
  });

  test('clear preserves exclusive ownership of the native draft', () async {
    final store = FileDraftStore(directory: directory);
    await store.acquireSession();
    final contender = await start();
    expect(await contender.acquire(), 'busy');

    await store.clear();

    expect(await File('${directory.path}/.session.lock').exists(), isTrue);
    expect(await contender.acquire(), 'busy');
  });

  test('a second local owner cannot release the process lock', () async {
    final store = FileDraftStore(directory: directory);
    await store.acquireSession();
    await expectLater(
      FileDraftStore(directory: directory).acquireSession(),
      throwsA(isA<DraftInUseException>()),
    );
    final contender = await start();
    expect(await contender.acquire(), 'busy');
  });
}
