import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/cache_copies.dart';
import 'package:fosscanner/services/pdf_export_files.dart';

const _uuid = '3f2a9c1e-7b4d-4e8a-9f0c-12ab34cd56ef';

void main() {
  late Directory root;
  late Directory cache;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cache_copies_');
    cache = Directory('${root.path}/cache')..createSync();
    outside = Directory('${root.path}/outside')..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<Directory> provider() async => cache;

  File file(String path) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  group('matchers', () {
    test('export names match only what pdfExportFileName produces', () {
      final time = DateTime(2026, 11, 19, 14, 5);
      expect(
        isExportFileName(pdfExportFileName(time, searchable: false)),
        isTrue,
      );
      expect(
        isExportFileName(pdfExportFileName(time, searchable: true)),
        isTrue,
      );
      for (final name in [
        'Scan.pdf',
        'Scan 2026-11-19 14-05.PDF',
        'Scan 2026-11-19 14-05 (1).pdf',
        'Invoice 2026-11-19 14-05.pdf',
        'Scan 2026-11-19 14-05.pdf.jpg',
        '../Scan 2026-11-19 14-05.pdf',
      ]) {
        expect(isExportFileName(name), isFalse, reason: name);
      }
    });

    test('picker directories are bare lowercase UUIDs', () {
      expect(isImagePickerCopyDirectoryName(_uuid), isTrue);
      for (final name in [
        _uuid.toUpperCase(),
        '${_uuid}x',
        'fosscanner_export_123',
        'share_plus',
        'shared_images',
        'flutter_engine',
      ]) {
        expect(isImagePickerCopyDirectoryName(name), isFalse, reason: name);
      }
    });

    test('picker files are scaled images and camera captures', () {
      for (final name in [
        'scaled_IMG_0001.jpg',
        'scaled_photo.PNG',
        'scaled_x.webp',
        '${_uuid}1234567890.jpg',
        '$_uuid.jpg',
      ]) {
        expect(isImagePickerCacheFileName(name), isTrue, reason: name);
      }
      for (final name in [
        'scaled_notes.txt',
        'scaled_.jpg.pdf',
        'IMG_0001.jpg',
        'Scan 2026-11-19 14-05.pdf',
        'draft.json',
        '${_uuid}1234.mp4',
      ]) {
        expect(isImagePickerCacheFileName(name), isFalse, reason: name);
      }
    });
  });

  group('deleteSharedExportCopies', () {
    test('removes only export copies in share_plus', () async {
      final ours = file('${cache.path}/share_plus/Scan 2026-11-19 14-05.pdf');
      final searchable = file(
        '${cache.path}/share_plus/Scan 2026-11-19 14-06 (searchable).pdf',
      );
      final foreign = file('${cache.path}/share_plus/report.pdf');
      final sameNameElsewhere = file('${cache.path}/Scan 2026-11-19 14-05.pdf');

      await deleteSharedExportCopies(temporaryDirectory: provider);

      expect(ours.existsSync(), isFalse);
      expect(searchable.existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
      expect(sameNameElsewhere.existsSync(), isTrue);
    });

    test('a file name limits the deletion to that copy', () async {
      final first = file('${cache.path}/share_plus/Scan 2026-11-19 14-05.pdf');
      final second = file('${cache.path}/share_plus/Scan 2026-11-19 14-06.pdf');
      await deleteSharedExportCopies(
        fileName: 'Scan 2026-11-19 14-06.pdf',
        temporaryDirectory: provider,
      );
      expect(first.existsSync(), isTrue);
      expect(second.existsSync(), isFalse);
    });

    test('never follows a linked share folder out of the cache', () async {
      final target = file('${outside.path}/Scan 2026-11-19 14-05.pdf');
      Link('${cache.path}/share_plus').createSync(outside.path);
      await deleteSharedExportCopies(temporaryDirectory: provider);
      expect(target.existsSync(), isTrue);
    });

    test('a missing cache or folder is not an error', () async {
      await deleteSharedExportCopies(temporaryDirectory: provider);
      await deleteSharedExportCopies(
        temporaryDirectory: () async => throw const FileSystemException('x'),
      );
    });
  });

  group('sweepImagePickerCopies', () {
    test('removes picker copies and nothing else', () async {
      final scaled = file('${cache.path}/scaled_IMG_1.jpg');
      final camera = file('${cache.path}/${_uuid}42.jpg');
      final copy = file('${cache.path}/$_uuid/IMG_1.jpg');
      final export = file('${cache.path}/fosscanner_export_1/Scan.pdf');
      final shared = file('${cache.path}/shared_images/a.jpg');
      final other = file('${cache.path}/IMG_2.jpg');
      final nested = file(
        '${cache.path}/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/sub/x.jpg',
      );

      await sweepImagePickerCopies(temporaryDirectory: provider);

      expect(scaled.existsSync(), isFalse);
      expect(camera.existsSync(), isFalse);
      expect(copy.existsSync(), isFalse);
      expect(copy.parent.existsSync(), isFalse);
      expect(export.existsSync(), isTrue);
      expect(shared.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
      // A UUID-named directory with subdirectories is not a picker copy.
      expect(nested.existsSync(), isTrue);
    });

    test('never follows links out of the cache', () async {
      final target = file('${outside.path}/IMG_1.jpg');
      final linkedFile = file('${outside.path}/scaled_IMG_2.jpg');
      Link('${cache.path}/$_uuid').createSync(outside.path);
      Link('${cache.path}/scaled_IMG_2.jpg').createSync(linkedFile.path);

      await sweepImagePickerCopies(temporaryDirectory: provider);

      expect(target.existsSync(), isTrue);
      expect(linkedFile.existsSync(), isTrue);
    });
  });

  group('isImagePickerCopy', () {
    test('accepts picker copies inside the cache only', () async {
      final scaled = file('${cache.path}/scaled_IMG_1.jpg');
      final copy = file('${cache.path}/$_uuid/IMG_1.jpg');
      final original = file('${outside.path}/scaled_IMG_1.jpg');
      final outsideUuid = file('${outside.path}/$_uuid/IMG_1.jpg');
      final plain = file('${cache.path}/IMG_1.jpg');
      final export = file('${cache.path}/fosscanner_export_1/Scan.pdf');

      expect(
        await isImagePickerCopy(scaled.path, temporaryDirectory: provider),
        isTrue,
      );
      expect(
        await isImagePickerCopy(copy.path, temporaryDirectory: provider),
        isTrue,
      );
      for (final path in [
        original.path,
        outsideUuid.path,
        plain.path,
        export.path,
        '${cache.path}/scaled_missing.jpg',
        '${cache.path}/$_uuid/../scaled_IMG_1.jpg/../../outside/x.jpg',
      ]) {
        expect(
          await isImagePickerCopy(path, temporaryDirectory: provider),
          isFalse,
          reason: path,
        );
      }
    });

    test('rejects a link inside the cache to a file outside it', () async {
      final original = file('${outside.path}/IMG_1.jpg');
      Link('${cache.path}/scaled_IMG_1.jpg').createSync(original.path);
      expect(
        await isImagePickerCopy(
          '${cache.path}/scaled_IMG_1.jpg',
          temporaryDirectory: provider,
        ),
        isFalse,
      );
    });
  });

  test(
    'deleteImagePickerCopy removes a copy and its empty directory',
    () async {
      final copy = file('${cache.path}/$_uuid/IMG_1.jpg');
      final scaled = file('${cache.path}/scaled_IMG_1.jpg');
      final original = file('${outside.path}/scaled_IMG_1.jpg');
      for (final target in [copy, scaled, original]) {
        await deleteImagePickerCopy(target.path, temporaryDirectory: provider);
      }
      expect(copy.existsSync(), isFalse);
      expect(copy.parent.existsSync(), isFalse);
      expect(scaled.existsSync(), isFalse);
      expect(original.existsSync(), isTrue);
    },
  );

  test('a copy that is already gone counts as removed', () async {
    final logged = <String?>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) => logged.add(message);
    addTearDown(() => debugPrint = print);
    final copies = [
      for (var i = 0; i < 20; i++) file('${cache.path}/$_uuid/IMG_$i.jpg'),
    ];
    // After an import the per-image cleanup and the sweep race for the same
    // files; whichever loses finds nothing left to delete.
    await Future.wait([
      for (final copy in copies)
        deleteImagePickerCopy(copy.path, temporaryDirectory: provider),
      sweepImagePickerCopies(temporaryDirectory: provider),
    ]);
    expect(copies.any((copy) => copy.existsSync()), isFalse);
    expect(logged, isEmpty);
  });
}
