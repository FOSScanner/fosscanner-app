import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/services/document_processor_native.dart';
import 'package:fosscanner/services/draft_store_native.dart';
import 'package:fosscanner/services/draft_store_base.dart';
import 'package:fosscanner/services/image_metadata.dart';

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

  test('keeps the source density of imported pages, optionally', () async {
    final store = FileDraftStore(directory: directory);
    final imported = page(2, PageFilter.original).withSourceDpi(212.5);
    await store.save([page(1, PageFilter.original), imported]);
    final manifestFile = File('${directory.path}/current/manifest.json');
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
    final entries = (manifest['pages']! as List).cast<Map<String, Object?>>();
    // Photos write no density, so the schema is unchanged for them.
    expect(entries[0].containsKey('sourceDpi'), isFalse);
    expect(entries[1]['sourceDpi'], 212.5);
    expect(manifest['schemaVersion'], 1);

    var restored = await store.load();
    expect(restored.map((page) => page.sourceDpi), [null, 212.5]);

    // An unusable value restores the page with the default density.
    entries[1]['sourceDpi'] = 'wide';
    await manifestFile.writeAsString(jsonEncode(manifest));
    restored = await store.load();
    expect(restored.map((page) => page.sourceDpi), [null, null]);
  });

  test(
    'a corrupt or incomplete manifest fails without overwriting data',
    () async {
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

      final store = FileDraftStore(directory: directory);
      final manifest = File('${current.path}/manifest.json');
      final original = await manifest.readAsString();
      await expectLater(store.load(), throwsA(isA<DraftRestoreException>()));
      await expectLater(
        store.save([page(1, PageFilter.original)]),
        throwsA(isA<DraftRestoreException>()),
      );
      // A fresh store must not bypass the failed-restoration protection either.
      await expectLater(
        FileDraftStore(directory: directory).save([]),
        throwsA(isA<DraftRestoreException>()),
      );
      expect(await manifest.readAsString(), original);
    },
  );

  test(
    'missing draft and a valid empty draft are not restoration errors',
    () async {
      final missingRoot = Directory('${directory.path}/missing');
      expect(await FileDraftStore(directory: missingRoot).load(), isEmpty);
      final store = FileDraftStore(directory: directory);
      expect(await store.load(), isEmpty);
      await store.save([]);
      expect(await FileDraftStore(directory: directory).load(), isEmpty);
    },
  );

  test(
    'an incomplete generation is not mistaken for a missing draft',
    () async {
      await Directory('${directory.path}/current').create();
      final store = FileDraftStore(directory: directory);
      await expectLater(store.load(), throwsA(isA<DraftRestoreException>()));
      await expectLater(store.save([]), throwsA(isA<DraftRestoreException>()));
      expect(await Directory('${directory.path}/current').exists(), isTrue);
    },
  );

  test(
    'a non-directory draft root reports failure rather than absence',
    () async {
      final root = File('${directory.path}/occupied');
      await root.writeAsString('preserve');
      final store = FileDraftStore(directory: Directory(root.path));
      await expectLater(store.load(), throwsA(isA<DraftRestoreException>()));
      await expectLater(store.save([]), throwsA(isA<DraftRestoreException>()));
      expect(await root.readAsString(), 'preserve');
    },
  );

  test(
    'current read failure still recovers and promotes a valid backup',
    () async {
      final original = page(2, PageFilter.original);
      final store = FileDraftStore(directory: directory);
      await store.save([original]);
      await store.save([page(3, PageFilter.grayscale)]);
      final reader = FileDraftStore(
        directory: directory,
        beforeLoad: (stage) {
          if (stage == DraftLoadStage.beforeCurrentRead) {
            throw const FileSystemException('private read error');
          }
        },
      );
      final recovered = await reader.load();
      expectPage(recovered.single, original);
      await reader.save(recovered);
    },
  );

  test(
    'read failures preserve generations, block saves, and allow retry',
    () async {
      final original = page(2, PageFilter.original);
      final newest = page(3, PageFilter.grayscale);
      final writer = FileDraftStore(directory: directory);
      await writer.save([original]);
      await writer.save([newest]);
      var fail = true;
      final reader = FileDraftStore(
        directory: directory,
        beforeLoad: (_) {
          if (fail) throw const FileSystemException('private read error');
        },
      );
      await expectLater(reader.load(), throwsA(isA<DraftRestoreException>()));
      await expectLater(reader.save([]), throwsA(isA<DraftRestoreException>()));
      expect(await Directory('${directory.path}/current').exists(), isTrue);
      expect(await Directory('${directory.path}/backup').exists(), isTrue);
      fail = false;
      expectPage((await reader.load()).single, newest);
      await reader.save([original]);
      expectPage((await reader.load()).single, original);
    },
  );

  test(
    'promotion failure keeps valid backup and blocks saves until retry',
    () async {
      final original = page(2, PageFilter.original);
      final writer = FileDraftStore(directory: directory);
      await writer.save([original]);
      await writer.save([page(3, PageFilter.grayscale)]);
      await File(
        '${directory.path}/current/manifest.json',
      ).writeAsString('corrupt');
      final backupImage = File('${directory.path}/backup/page_0_original.bin');
      final originalBytes = await backupImage.readAsBytes();
      var fail = true;
      final reader = FileDraftStore(
        directory: directory,
        beforeLoad: (stage) {
          if (fail && stage == DraftLoadStage.beforeBackupPromotion) {
            throw const FileSystemException('private promotion error');
          }
        },
      );
      await expectLater(reader.load(), throwsA(isA<DraftRestoreException>()));
      await expectLater(reader.save([]), throwsA(isA<DraftRestoreException>()));
      expect(await backupImage.readAsBytes(), originalBytes);
      fail = false;
      expectPage((await reader.load()).single, original);
      await reader.save([original]);
    },
  );

  test(
    'corrupt current and backup require explicit clear before saving',
    () async {
      final store = FileDraftStore(directory: directory);
      await store.save([page(1, PageFilter.original)]);
      await store.save([page(2, PageFilter.grayscale)]);
      for (final generation in ['current', 'backup']) {
        await File(
          '${directory.path}/$generation/manifest.json',
        ).writeAsString('corrupt');
      }
      await expectLater(store.load(), throwsA(isA<DraftRestoreException>()));
      await expectLater(store.save([]), throwsA(isA<DraftRestoreException>()));
      await store.clear();
      await store.save([page(3, PageFilter.original)]);
      expect((await store.load()).single.brightness, 3.25);
    },
  );

  test(
    'failed clear does not authorize overwriting after failed restoration',
    () async {
      final root = File('${directory.path}/occupied');
      await root.writeAsString('preserve');
      final store = FileDraftStore(directory: Directory(root.path));
      await expectLater(store.load(), throwsA(isA<DraftRestoreException>()));
      await expectLater(store.clear(), throwsA(isA<DraftRestoreException>()));
      await root.delete();
      await Directory(root.path).create();
      await expectLater(store.save([]), throwsA(isA<DraftRestoreException>()));
      expect(await store.load(), isEmpty);
      await store.save([]);
    },
  );

  test(
    'explicit clear removes malformed generation entries without following links',
    () async {
      final outside = File('${directory.path}/keep.bin');
      await outside.writeAsString('preserve');
      await File(
        '${directory.path}/current',
      ).writeAsString('invalid generation');
      await Link('${directory.path}/backup').create(outside.absolute.path);
      final store = FileDraftStore(directory: directory);
      await expectLater(store.load(), throwsA(isA<DraftRestoreException>()));
      await store.clear();
      expect(await outside.readAsString(), 'preserve');
      expect(await store.load(), isEmpty);
      await store.save([page(1, PageFilter.original)]);
    },
  );

  test('round-trips native crops with a two-pixel edge', () async {
    final store = FileDraftStore(directory: directory);
    final first = page(1, PageFilter.original);
    const corners = [Offset.zero, Offset(2, 0), Offset(2, 80), Offset(0, 80)];

    for (final turns in [0, 1]) {
      final processed = processDocument(
        tinyPng,
        corners,
        filter: PageFilter.original,
        rotationQuarterTurns: turns,
        brightness: 0,
        contrast: 1,
      );
      expect(
        await readEncodedImageSize(processed),
        turns == 0 ? const Size(2, 80) : const Size(80, 2),
      );
      final narrow = ScannedPage(
        originalBytes: tinyPng,
        processedBytes: processed,
        corners: corners,
        rotationQuarterTurns: turns,
      );
      await store.save([first]);
      await store.save([first, narrow]);

      final restored = await FileDraftStore(directory: directory).load();

      expect(restored, hasLength(2));
      expectPage(restored[0], first);
      expectPage(restored[1], narrow);
    }
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
