import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/image_pdf_service.dart';
import 'package:fosscanner/services/pdf_export_options.dart';
import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';

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

late Directory _outputs;

String _outputPath() => '${_outputs.path}/document.pdf';

/// Writes the PDF to a file and reads it back for inspection.
Future<Uint8List> createImageOnlyPdf(
  List<Uint8List> pages, {
  PdfPageSize pageSize = PdfPageSize.original,
  PdfQuality quality = PdfQuality.high,
  void Function(int completed, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  await writeImageOnlyPdf(
    pages,
    _outputPath(),
    pageSize: pageSize,
    quality: quality,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
  final file = File(_outputPath());
  final bytes = await file.readAsBytes();
  await file.delete();
  return bytes;
}

List<List<double>> mediaBoxes(Uint8List pdf) =>
    RegExp(r'/MediaBox\s*\[([^\]]+)\]')
        .allMatches(latin1.decode(pdf))
        .map(
          (match) =>
              match[1]!.trim().split(RegExp(r'\s+')).map(double.parse).toList(),
        )
        .toList();

Uint8List noisyJpeg(int width, int height) {
  final random = math.Random(width * height);
  final image = im.Image(width: width, height: height, numChannels: 3);
  for (final pixel in image) {
    final v = 128 + random.nextInt(64);
    pixel
      ..r = v
      ..g = v
      ..b = v;
  }
  return im.encodeJpg(image, quality: 95);
}

void main() {
  setUp(() async {
    _outputs = await Directory.systemTemp.createTemp('image_pdf_test_');
  });

  tearDown(() async {
    // Every test leaves the directory empty: success paths delete what they
    // read back, and failures must not leave a partial PDF behind.
    expect(_outputs.listSync(), isEmpty);
    await _outputs.delete();
  });

  test('writes the finished document to the requested path', () async {
    final page = im.encodeJpg(im.Image(width: 20, height: 10));
    await writeImageOnlyPdf([page], _outputPath());
    final written = File(_outputPath());
    expect(latin1.decode(await written.readAsBytes()), startsWith('%PDF-'));
    await written.delete();
  });

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

  test('a cancel arriving during assembly still yields no document', () async {
    final page = im.encodePng(im.Image(width: 20, height: 10, numChannels: 3));
    // One poll per page plus one before assembly. Staying false for those
    // makes this cancel observable only on the poll that runs once the worker
    // has already produced the document.
    const pollsBeforeAssemblyEnds = 2;
    var polls = 0;
    await expectLater(
      createImageOnlyPdf([
        page,
      ], isCancelled: () => polls++ >= pollsBeforeAssemblyEnds),
      throwsA(isA<ImagePdfCancelledException>()),
    );
    expect(polls, pollsBeforeAssemblyEnds + 1);
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

  test('A4 and Letter exports use exact page boxes for every page', () async {
    final portrait = noisyJpeg(200, 300);
    final landscape = noisyJpeg(300, 200);
    final a4 = await createImageOnlyPdf([
      portrait,
      landscape,
    ], pageSize: PdfPageSize.a4);
    final boxes = mediaBoxes(a4);
    expect(boxes, hasLength(2));
    expect(boxes[0][2], closeTo(PdfPageFormat.a4.width, 0.01));
    expect(boxes[0][3], closeTo(PdfPageFormat.a4.height, 0.01));
    expect(boxes[1][2], closeTo(PdfPageFormat.a4.height, 0.01));
    expect(boxes[1][3], closeTo(PdfPageFormat.a4.width, 0.01));
    // High keeps the JPEG untouched even on a fixed page size.
    expect(embeddedJpegs(a4).first, orderedEquals(portrait));

    final letter = await createImageOnlyPdf([
      portrait,
    ], pageSize: PdfPageSize.letter);
    expect(mediaBoxes(letter).single.sublist(2), [612, 792]);
  });

  test('presets measurably shrink a representative 10-page document', () async {
    final pages = [for (var i = 0; i < 10; i++) noisyJpeg(620 + i, 877)];
    final high = await createImageOnlyPdf(pages, pageSize: PdfPageSize.a4);
    final balanced = await createImageOnlyPdf(
      pages,
      pageSize: PdfPageSize.a4,
      quality: PdfQuality.balanced,
    );
    final small = await createImageOnlyPdf(
      pages,
      pageSize: PdfPageSize.a4,
      quality: PdfQuality.small,
    );
    expect(balanced.length, lessThan(high.length * 0.75));
    expect(small.length, lessThan(balanced.length));
    expect(small.length, lessThan(high.length / 2));
    expect(mediaBoxes(small), hasLength(10));
  });
}
