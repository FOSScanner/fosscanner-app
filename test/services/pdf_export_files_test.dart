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
}
