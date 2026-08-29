import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/services/draft_store_native.dart';

void main() {
  late Directory directory;
  final tinyPng = File('assets/icon/icon.png').readAsBytesSync();

  setUp(() async {
    directory = Directory('.draft-store-test-tmp');
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  ScannedPage page(int seed, PageFilter filter) => ScannedPage(
    originalBytes: Uint8List.fromList(tinyPng),
    processedBytes: Uint8List.fromList(tinyPng),
    corners: [
      Offset(seed.toDouble(), seed + 0.5),
      Offset(seed + 10.0, seed + 1.5),
      Offset(seed + 11.0, seed + 12.5),
      Offset(seed + 1.0, seed + 13.5),
    ],
    filter: filter,
    rotationQuarterTurns: seed % 4,
    brightness: seed + 0.25,
    contrast: 1 + seed / 10,
  );

  void expectPage(ScannedPage actual, ScannedPage expected) {
    expect(actual.originalBytes, orderedEquals(expected.originalBytes));
    expect(actual.processedBytes, orderedEquals(expected.processedBytes));
    expect(actual.corners, orderedEquals(expected.corners));
    expect(actual.filter, expected.filter);
    expect(actual.rotationQuarterTurns, expected.rotationQuarterTurns);
    expect(actual.brightness, expected.brightness);
    expect(actual.contrast, expected.contrast);
  }

  test('round-trips every ScannedPage field in page order', () async {
    final store = FileDraftStore(directory: directory);
    final pages = [
      page(1, PageFilter.autoEnhance),
      page(7, PageFilter.blackAndWhite),
      page(3, PageFilter.grayscale),
    ];

    await store.save(pages);
    final restored = await store.load();

    expect(restored, hasLength(3));
    for (var index = 0; index < pages.length; index++) {
      expectPage(restored[index], pages[index]);
    }
    final manifestText = await File(
      '${directory.path}/current/manifest.json',
    ).readAsString();
    final manifest = jsonDecode(manifestText) as Map<String, Object?>;
    expect(manifest.keys, unorderedEquals(['schemaVersion', 'pages']));
    expect(manifest['schemaVersion'], 1);
    expect(
      manifestText,
      isNot(contains(base64Encode(tinyPng))),
      reason: 'image bytes belong in separate binary files',
    );
  });

  test('a corrupt or incomplete manifest loads as no draft', () async {
    final current = Directory('${directory.path}/current');
    await current.create();
    await File('${current.path}/manifest.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'pages': [
          {
            'corners': <Object>[],
            'filter': 'original',
            'rotationQuarterTurns': 0,
            'brightness': 0,
            'contrast': 1,
          },
        ],
      }),
    );

    final restored = await FileDraftStore(directory: directory).load();

    expect(restored, isEmpty);
  });

  test('a failed replacement preserves the previous valid draft', () async {
    final original = page(2, PageFilter.original);
    await FileDraftStore(directory: directory).save([original]);
    final failingStore = FileDraftStore(
      directory: directory,
      beforeCommit: (stage) {
        if (stage == DraftSaveStage.afterCurrentMoved) {
          throw const FileSystemException('injected replacement failure');
        }
      },
    );

    await expectLater(
      failingStore.save([page(9, PageFilter.grayscale)]),
      throwsA(isA<FileSystemException>()),
    );

    final restored = await FileDraftStore(directory: directory).load();
    expect(restored, hasLength(1));
    expectPage(restored.single, original);
  });

  test('falls back to the backup when current is corrupt', () async {
    final first = page(4, PageFilter.original);
    await FileDraftStore(directory: directory).save([first]);
    await FileDraftStore(
      directory: directory,
    ).save([page(5, PageFilter.grayscale)]);
    await File(
      '${directory.path}/current/manifest.json',
    ).writeAsString('{not-json');

    final restored = await FileDraftStore(directory: directory).load();

    expect(restored, hasLength(1));
    expectPage(restored.single, first);
    expect(await Directory('${directory.path}/current').exists(), isTrue);
    expect(await Directory('${directory.path}/backup').exists(), isFalse);
  });

  test('junk encoded image bytes fall back to the valid backup', () async {
    final first = page(6, PageFilter.autoEnhance);
    await FileDraftStore(directory: directory).save([first]);
    await FileDraftStore(
      directory: directory,
    ).save([page(7, PageFilter.blackAndWhite)]);
    await File(
      '${directory.path}/current/page_0_original.bin',
    ).writeAsBytes([1]);

    final restored = await FileDraftStore(directory: directory).load();

    expect(restored, hasLength(1));
    expectPage(restored.single, first);
  });

  test(
    'corrupt PNG payload with intact metadata restores and promotes backup',
    () async {
      final backupPage = page(6, PageFilter.autoEnhance);
      await FileDraftStore(directory: directory).save([backupPage]);
      await FileDraftStore(
        directory: directory,
      ).save([page(7, PageFilter.blackAndWhite)]);

      final corrupted = Uint8List.fromList(tinyPng);
      var idat = -1;
      for (var index = 0; index <= corrupted.length - 4; index++) {
        if (String.fromCharCodes(corrupted.sublist(index, index + 4)) ==
            'IDAT') {
          idat = index;
          break;
        }
      }
      expect(idat, greaterThanOrEqualTo(0));
      // Keep the PNG signature and IHDR dimensions intact, but invalidate the
      // zlib stream in IDAT. Descriptor-only validation still accepts it.
      corrupted[idat + 4] = 0;
      await File(
        '${directory.path}/current/page_0_processed.bin',
      ).writeAsBytes(corrupted);

      final restored = await FileDraftStore(directory: directory).load();

      expect(restored, hasLength(1));
      expectPage(restored.single, backupPage);
      expect(await Directory('${directory.path}/current').exists(), isTrue);
      expect(await Directory('${directory.path}/backup').exists(), isFalse);
    },
  );

  test('failed save after fallback preserves the recovered draft', () async {
    final recovered = page(8, PageFilter.original);
    await FileDraftStore(directory: directory).save([recovered]);
    await FileDraftStore(
      directory: directory,
    ).save([page(9, PageFilter.grayscale)]);
    await File(
      '${directory.path}/current/page_0_processed.bin',
    ).writeAsBytes([1]);
    final restored = await FileDraftStore(directory: directory).load();
    expectPage(restored.single, recovered);

    final failingStore = FileDraftStore(
      directory: directory,
      beforeCommit: (stage) {
        if (stage == DraftSaveStage.afterCurrentMoved) {
          throw const FileSystemException('injected replacement failure');
        }
      },
    );
    await expectLater(
      failingStore.save([page(10, PageFilter.blackAndWhite)]),
      throwsA(isA<FileSystemException>()),
    );

    final afterFailure = await FileDraftStore(directory: directory).load();
    expect(afterFailure, hasLength(1));
    expectPage(afterFailure.single, recovered);
  });

  test('clear removes current, backup, and staging data', () async {
    final store = FileDraftStore(directory: directory);
    await store.save([page(1, PageFilter.original)]);

    await store.clear();

    expect(await store.load(), isEmpty);
    expect(await directory.list().toList(), isEmpty);
  });
}
