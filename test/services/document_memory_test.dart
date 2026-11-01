import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/services/document_memory.dart';

ScannedPage _page(Uint8List original, Uint8List processed) => ScannedPage(
  originalBytes: original,
  processedBytes: processed,
  corners: const [],
);

void main() {
  test('empty documents retain no encoded images', () {
    expect(retainedPageImageBytes(const []), 0);
  });

  test('counts distinct original and processed image allocations', () {
    expect(retainedPageImageBytes([_page(Uint8List(11), Uint8List(13))]), 24);
  });

  test('snapshots and pages sharing image buffers are counted once', () {
    final original = Uint8List(11);
    final processed = Uint8List(13);
    final page = _page(original, processed);
    expect(
      retainedPageImageBytes([page, page, _page(original, processed)]),
      24,
    );
    expect(retainedPageImageBytes([_page(original, original)]), 11);
  });

  test('views retain the whole backing allocation without double counting', () {
    final bytes = Uint8List(100);
    final original = Uint8List.sublistView(bytes, 1, 10);
    final processed = Uint8List.sublistView(bytes, 20, 30);
    expect(retainedPageImageBytes([_page(original, processed)]), 100);
  });

  test('equal contents in different allocations still consume memory', () {
    expect(retainedPageImageBytes([_page(Uint8List(11), Uint8List(11))]), 22);
  });
}
