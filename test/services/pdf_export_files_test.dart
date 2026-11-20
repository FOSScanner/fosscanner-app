import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/pdf_export_files.dart';

void main() {
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('export_files_test_');
  });

  tearDown(() => cache.delete(recursive: true));

  List<String> names() =>
      cache
          .listSync()
          .map(
            (entry) => entry.uri.pathSegments.lastWhere(
              (segment) => segment.isNotEmpty,
            ),
          )
          .toList()
        ..sort();

  test('each export gets its own directory that delete removes', () async {
    final first = await createPdfExportDirectory(
      temporaryDirectory: () async => cache,
    );
    final second = await createPdfExportDirectory(
      temporaryDirectory: () async => cache,
    );
    expect(first.directory.path, isNot(second.directory.path));
    final file = first.fileNamed('Scan.pdf');
    await file.writeAsString('%PDF-');
    expect(file.parent.path, first.directory.path);

    first.delete();
    expect(first.directory.existsSync(), isFalse);
    expect(second.directory.existsSync(), isTrue);
    // Deleting twice is harmless.
    first.delete();
  });

  test('the export copy goes once share_plus has its own copy', () async {
    final export = await createPdfExportDirectory(
      temporaryDirectory: () async => cache,
    );
    final pdf = export.fileNamed('Scan.pdf')..writeAsStringSync('%PDF-1.5');
    final shareFolder = Directory('${cache.path}/share_plus')..createSync();
    // A copy an earlier share left with the same name is not this one.
    final stale = File('${shareFolder.path}/Scan.pdf')
      ..writeAsStringSync('%PDF-1.5');
    final stop = export.deleteOnceShared(
      pdf,
      interval: const Duration(milliseconds: 5),
    );
    expect(stale.existsSync(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(export.directory.existsSync(), isTrue);

    // A partial copy is not enough.
    final copy = File('${shareFolder.path}/Scan.pdf')..writeAsStringSync('%P');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(export.directory.existsSync(), isTrue);

    copy.writeAsStringSync('%PDF-1.5');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(export.directory.existsSync(), isFalse);
    expect(copy.existsSync(), isTrue);
    stop();
    // The flow's own cleanup afterwards is harmless.
    export.delete();
  });

  test(
    'without a share copy the export stays until the share returns',
    () async {
      final export = await createPdfExportDirectory(
        temporaryDirectory: () async => cache,
      );
      final pdf = export.fileNamed('Scan.pdf')..writeAsStringSync('%PDF-1.5');
      final stop = export.deleteOnceShared(
        pdf,
        interval: const Duration(milliseconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(pdf.existsSync(), isTrue);
      stop();
      export.delete();
      expect(export.directory.existsSync(), isFalse);
    },
  );

  test('the startup sweep removes only stale export directories', () async {
    final stale = Directory('${cache.path}/${pdfExportDirectoryPrefix}abc')
      ..createSync();
    File('${stale.path}/Scan.pdf').writeAsStringSync('%PDF-');
    Directory('${cache.path}/fosscanner_ocr_job').createSync();
    Directory('${cache.path}/share_plus').createSync();
    File('${cache.path}/${pdfExportDirectoryPrefix}file').writeAsStringSync('');

    await sweepStalePdfExports(temporaryDirectory: () async => cache);

    expect(names(), [
      '${pdfExportDirectoryPrefix}file',
      'fosscanner_ocr_job',
      'share_plus',
    ]);
  });

  test('the sweep never throws', () async {
    await sweepStalePdfExports(
      temporaryDirectory: () async => throw const FileSystemException('no'),
    );
    await sweepStalePdfExports(
      temporaryDirectory: () async => Directory('${cache.path}/missing'),
    );
  });

  group('file names', () {
    test('are readable, sortable and locale-independent', () {
      final time = DateTime(2026, 1, 2, 3, 4, 59);
      expect(
        pdfExportFileName(time, searchable: false),
        'Scan 2026-01-02 03-04.pdf',
      );
      expect(
        pdfExportFileName(DateTime(2026, 11, 19, 14, 5), searchable: true),
        'Scan 2026-11-19 14-05 (searchable).pdf',
      );
    });

    test('an image-only fallback drops only the searchable marker', () {
      expect(
        withoutSearchableSuffix('Scan 2026-11-19 14-05 (searchable).pdf'),
        'Scan 2026-11-19 14-05.pdf',
      );
      expect(withoutSearchableSuffix('Taxes (Searchable).PDF'), 'Taxes.pdf');
      expect(withoutSearchableSuffix('Scan 2026-11-19 14-05.pdf'), isNull);
      expect(withoutSearchableSuffix('Taxes (searchable) v2.pdf'), isNull);
      expect(withoutSearchableSuffix(' (searchable).pdf'), isNull);
    });

    test('sanitizing removes separators, reserved and control characters', () {
      expect(
        sanitizePdfFileName('a/b\\c:d*e?f"g<h>i|j.pdf'),
        'a b c d e f g h i j.pdf',
      );
      expect(sanitizePdfFileName('tab\there\nnew.PDF'), 'tab here new.pdf');
      expect(sanitizePdfFileName('../../etc/passwd'), 'etc passwd.pdf');
      expect(sanitizePdfFileName('   '), 'Scan.pdf');
      expect(sanitizePdfFileName('.pdf'), 'Scan.pdf');
      expect(sanitizePdfFileName('x' * 300), '${'x' * 100}.pdf');
    });
  });
}
