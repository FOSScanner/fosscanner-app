import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/app_preferences.dart';

void main() {
  late Directory directory;
  late FileAppPreferencesStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('preferences_test_');
    store = FileAppPreferencesStore(directory: () async => directory);
  });

  tearDown(() => directory.delete(recursive: true));

  File preferencesFile() =>
      File('${directory.path}/${FileAppPreferencesStore.fileName}');

  test('a missing file yields defaults', () async {
    expect(await store.load(), const AppPreferences());
    expect(const AppPreferences().searchablePdf, isFalse);
  });

  test('saved preferences survive a new store instance', () async {
    await store.save(const AppPreferences(searchablePdf: true));
    final reopened = FileAppPreferencesStore(directory: () async => directory);
    expect(await reopened.load(), const AppPreferences(searchablePdf: true));
    // Only the final file remains; the temporary write was renamed.
    expect(directory.listSync().map((entry) => entry.uri.pathSegments.last), [
      FileAppPreferencesStore.fileName,
    ]);
  });

  for (final (name, contents) in [
    ('invalid JSON', '{"searchablePdf": tr'),
    ('a non-object', '[true]'),
    ('a wrongly typed field', '{"searchablePdf": "yes"}'),
    ('binary data', String.fromCharCodes([0, 255, 254, 1])),
  ]) {
    test('a file with $name falls back to defaults', () async {
      await preferencesFile().writeAsString(contents);
      expect(await store.load(), const AppPreferences());
    });
  }

  test('unknown fields are ignored', () async {
    await preferencesFile().writeAsString(
      '{"searchablePdf": true, "fromTheFuture": 3}',
    );
    expect(await store.load(), const AppPreferences(searchablePdf: true));
  });

  test('an oversized file is not parsed', () async {
    await preferencesFile().writeAsString(
      '{"searchablePdf": true, "padding": "${'x' * 70000}"}',
    );
    expect(await store.load(), const AppPreferences());
  });

  test('an unavailable directory loads defaults', () async {
    final broken = FileAppPreferencesStore(
      directory: () async => throw const FileSystemException('denied'),
    );
    expect(await broken.load(), const AppPreferences());
  });

  test('saves apply in call order', () async {
    final first = store.save(const AppPreferences(searchablePdf: true));
    final second = store.save(const AppPreferences());
    await Future.wait([first, second]);
    expect(await store.load(), const AppPreferences());
  });

  test(
    'a failed save reports its error but does not block later saves',
    () async {
      var fail = true;
      final flaky = FileAppPreferencesStore(
        directory: () async {
          if (fail) throw const FileSystemException('denied');
          return directory;
        },
      );
      await expectLater(
        flaky.save(const AppPreferences(searchablePdf: true)),
        throwsA(isA<FileSystemException>()),
      );
      fail = false;
      await flaky.save(const AppPreferences(searchablePdf: true));
      expect(await store.load(), const AppPreferences(searchablePdf: true));
    },
  );

  test('the memory store keeps the last saved value', () async {
    final memory = MemoryAppPreferencesStore();
    expect(await memory.load(), const AppPreferences());
    await memory.save(const AppPreferences(searchablePdf: true));
    expect(await memory.load(), const AppPreferences(searchablePdf: true));
  });
}
