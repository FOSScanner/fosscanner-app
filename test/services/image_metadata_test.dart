import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/image_metadata.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  test('reads dimensions from a valid encoded image', () async {
    final bytes = File('assets/icon/icon.png').readAsBytesSync();

    final size = await readEncodedImageSize(bytes);

    expect(size, const Size(1024, 1024));
    expect(() => validateSourceImageSize(size), returnsNormally);
  });

  test('reads an XFile stream bounded to its declared length', () async {
    final file = XFile('assets/icon/icon.png');
    final length = await file.length();

    final bytes = await readBoundedBytes(file.openRead(0, length));
    final size = await readEncodedImageSize(bytes);

    expect(bytes, isNotEmpty);
    expect(size.width, greaterThan(0));
  });

  test('caps incoming reads to the remaining document capacity', () {
    expect(
      availableEncodedImageBytes(currentBytes: 255 * 1024 * 1024),
      1024 * 1024,
    );
    expect(availableEncodedImageBytes(currentBytes: 0), maxEncodedImageBytes);
  });

  test('stops accumulating encoded data at the byte limit', () async {
    final stream = Stream.fromIterable([
      Uint8List.fromList(const [1, 2]),
      Uint8List.fromList(const [3, 4]),
    ]);

    await expectLater(
      readBoundedBytes(stream, maxBytes: 3),
      throwsA(isA<EncodedImageTooLargeError>()),
    );
  });

  test('rejects additions that exceed aggregate document memory limits', () {
    expect(
      canRetainDocument(
        currentBytes: 8,
        currentPages: 1,
        incomingBytes: 3,
        maxBytes: 10,
        maxPages: 2,
      ),
      isFalse,
    );
    expect(
      canRetainDocument(
        currentBytes: 1,
        currentPages: 2,
        incomingBytes: 1,
        maxBytes: 10,
        maxPages: 2,
      ),
      isFalse,
    );
  });

  test('rejects page replacements that exceed aggregate memory', () {
    expect(
      canReplaceDocumentPage(
        currentBytes: 10,
        currentPages: 2,
        replacedBytes: 1,
        replacementBytes: 2,
        maxBytes: 10,
        maxPages: 2,
      ),
      isFalse,
    );
    expect(
      canReplaceDocumentPage(
        currentBytes: 10,
        currentPages: 2,
        replacedBytes: 2,
        replacementBytes: 1,
        maxBytes: 10,
        maxPages: 2,
      ),
      isTrue,
    );
  });

  test('rejects source images whose decoded allocation is too large', () {
    expect(
      () => validateSourceImageSize(
        const Size(maxSourceImageEdge + 1, maxSourceImageEdge + 1),
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('rejects malformed source dimensions', () {
    for (final size in [
      Size.zero,
      const Size(double.infinity, 100),
      const Size(double.nan, 100),
    ]) {
      expect(
        () => validateSourceImageSize(size),
        throwsA(isA<FormatException>()),
        reason: '$size',
      );
    }
  });
}
