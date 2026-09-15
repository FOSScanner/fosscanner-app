import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/image_pdf_service.dart';
import 'package:image/image.dart' as im;

List<Uint8List> embeddedJpegs(Uint8List pdf) {
  final images = <Uint8List>[];
  for (var start = 0; start < pdf.length - 1; start++) {
    if (pdf[start] != 0xff || pdf[start + 1] != 0xd8) continue;
    for (var end = start + 2; end < pdf.length - 1; end++) {
      if (pdf[end] == 0xff && pdf[end + 1] == 0xd9) {
        images.add(Uint8List.sublistView(pdf, start, end + 2));
        start = end + 1;
        break;
      }
    }
  }
  return images;
}

void main() {
  test('retains original JPEG bytes without another lossy encoding', () async {
    final source = im.Image(width: 200, height: 100, numChannels: 3);
    im.fill(source, color: im.ColorRgb8(30, 100, 180));
    final jpeg = im.encodeJpg(source, quality: 83);
    final pdf = await createImageOnlyPdf([jpeg]);
    expect(embeddedJpegs(pdf).single, orderedEquals(jpeg));
  });

  test(
    'compresses PNG pages while preserving page order, size, and white background',
    () async {
      final first = im.Image(width: 200, height: 100, numChannels: 4);
      im.fill(first, color: im.ColorRgba8(255, 0, 0, 0));
      im.fillRect(
        first,
        x1: 50,
        y1: 25,
        x2: 150,
        y2: 75,
        color: im.ColorRgba8(255, 0, 0, 255),
      );
      final second = im.Image(width: 100, height: 200, numChannels: 3);
      im.fill(second, color: im.ColorRgb8(0, 0, 255));
      final pdf = await createImageOnlyPdf([
        im.encodePng(first),
        im.encodePng(second),
      ]);
      final images = embeddedJpegs(
        pdf,
      ).map((bytes) => im.decodeJpg(bytes)!).toList();
      expect(images, hasLength(2));
      expect((images[0].width, images[0].height), (200, 100));
      expect((images[1].width, images[1].height), (100, 200));
      final white = images[0].getPixel(5, 5);
      expect([white.r, white.g, white.b], everyElement(greaterThan(245)));
      final red = images[0].getPixel(100, 50);
      expect(red.r, greaterThan(245));
      expect(red.g, lessThan(10));
      final blue = images[1].getPixel(50, 100);
      expect(blue.b, greaterThan(245));
      expect(blue.r, lessThan(10));
      final boxes = RegExp(r'/MediaBox\s*\[([^\]]+)\]')
          .allMatches(latin1.decode(pdf))
          .map(
            (match) => match[1]!
                .trim()
                .split(RegExp(r'\s+'))
                .map(double.parse)
                .toList(),
          )
          .toList();
      expect(boxes, [
        [0, 0, 96, 48],
        [0, 0, 48, 96],
      ]);
    },
  );

  test('rejects undecodable page data', () async {
    await expectLater(
      createImageOnlyPdf([
        Uint8List.fromList([1, 2, 3]),
      ]),
      throwsA(anything),
    );
  });

  test('reports one progress update per converted page', () async {
    final page = im.encodePng(im.Image(width: 20, height: 10, numChannels: 3));
    final updates = <List<int>>[];
    await createImageOnlyPdf([
      page,
      page,
    ], onProgress: (completed, total) => updates.add([completed, total]));
    expect(updates, [
      [1, 2],
      [2, 2],
    ]);
  });

  test('cancelling leaves the remaining pages unconverted', () async {
    final page = im.encodePng(im.Image(width: 20, height: 10, numChannels: 3));
    var converted = 0;
    await expectLater(
      createImageOnlyPdf(
        [page, page, page],
        onProgress: (completed, _) => converted = completed,
        isCancelled: () => converted >= 1,
      ),
      throwsA(isA<ImagePdfCancelledException>()),
    );
    expect(converted, 1);
  });

  test('an export cancelled up front decodes nothing at all', () async {
    // Page data no decoder accepts: reaching it would throw something else.
    await expectLater(
      createImageOnlyPdf([
        Uint8List.fromList([1, 2, 3]),
      ], isCancelled: () => true),
      throwsA(isA<ImagePdfCancelledException>()),
    );
  });
}
