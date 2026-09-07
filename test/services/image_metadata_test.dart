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

  test('accepts source dimensions exactly at the edge-only boundary', () {
    expect(
      () => validateSourceImageSize(Size(maxSourceImageEdge.toDouble(), 3)),
      returnsNormally,
    );
    expect(
      () =>
          validateSourceImageSize(Size((maxSourceImageEdge + 1).toDouble(), 3)),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('accepts source dimensions exactly at the pixel-only boundary', () {
    expect(
      () => validateSourceImageSize(const Size(4000, 5000)),
      returnsNormally,
    );
    expect(
      () => validateSourceImageSize(const Size(4001, 5000)),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('rejects source dimensions below three pixels per edge', () {
    expect(
      () => validateSourceImageSize(const Size(2, 3)),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => validateSourceImageSize(const Size(3, 2)),
      throwsA(isA<UnsupportedError>()),
    );
    expect(() => validateSourceImageSize(const Size(3, 3)), returnsNormally);
  });

  test('accepts a compressed 20MP image when processing headroom remains', () {
    const encodedBytes = 64 * 1024;

    expect(
      estimateImageProcessingWorkingSet(
        currentRetainedBytes: 0,
        encodedBytes: encodedBytes,
        size: const Size(4000, 5000),
      ),
      encodedBytes + 224000000,
    );
    expect(
      canProcessSourceImage(
        currentRetainedBytes: 0,
        encodedBytes: encodedBytes,
        size: const Size(4000, 5000),
      ),
      isTrue,
    );
  });

  test('rejects a compressed 20MP image near the processing budget', () {
    expect(
      canProcessSourceImage(
        currentRetainedBytes: 255 * 1024 * 1024,
        encodedBytes: 64 * 1024,
        size: const Size(4000, 5000),
      ),
      isFalse,
    );
  });

  test('20MP processing acceptance follows exact retained headroom', () {
    const size = Size(4000, 5000);
    const encodedBytes = 64 * 1024;
    const transientBytes = encodedBytes + 224000000;
    const retainedHeadroom =
        maxImageProcessingWorkingSetBytes - transientBytes;

    expect(
      canProcessSourceImage(
        currentRetainedBytes: retainedHeadroom,
        encodedBytes: encodedBytes,
        size: size,
      ),
      isTrue,
    );
    expect(
      canProcessSourceImage(
        currentRetainedBytes: retainedHeadroom + 1,
        encodedBytes: encodedBytes,
        size: size,
      ),
      isFalse,
    );
  });

  test('estimates source decode and bounded warp storage independently', () {
    expect(estimateDecodedOpenCvBytes(const Size(100, 100)), 200000);
  });

  test('processing estimate includes retained, encoded, and decoded bytes', () {
    const size = Size(10, 20);
    final decodedEstimate = estimateDecodedOpenCvBytes(size);

    expect(
      estimateImageProcessingWorkingSet(
        currentRetainedBytes: 11,
        encodedBytes: 13,
        size: size,
      ),
      11 + 13 + decodedEstimate,
    );
    expect(decodedEstimate, greaterThan(10 * 20 * 4));
  });

  test('processing estimator rejects negative counters and dimensions', () {
    expect(
      () => estimateImageProcessingWorkingSet(
        currentRetainedBytes: -1,
        encodedBytes: 0,
        size: const Size(100, 100),
      ),
      throwsArgumentError,
    );
    expect(
      () => estimateImageProcessingWorkingSet(
        currentRetainedBytes: 0,
        encodedBytes: -1,
        size: const Size(100, 100),
      ),
      throwsArgumentError,
    );
    expect(
      () => estimateDecodedOpenCvBytes(const Size(-100, 100)),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => estimateDecodedOpenCvBytes(const Size(100.5, 100)),
      throwsA(isA<FormatException>()),
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
