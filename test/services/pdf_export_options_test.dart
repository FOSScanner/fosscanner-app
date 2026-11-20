import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/pdf_export_options.dart';
import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';

PdfPagePlan plan(int w, int h, PdfPageSize size, PdfQuality quality) =>
    planPdfPage(
      sourceWidth: w,
      sourceHeight: h,
      pageSize: size,
      quality: quality,
    );

/// A photo-like page: noise makes JPEG size depend on resolution and quality.
Uint8List noisyJpeg(int width, int height, {int seed = 1}) {
  final random = math.Random(seed);
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
  test('page boxes have the correct physical dimensions', () {
    expect(PdfPageSize.a4.format!.width, closeTo(210 / 25.4 * 72, 0.01));
    expect(PdfPageSize.a4.format!.height, closeTo(297 / 25.4 * 72, 0.01));
    expect(PdfPageSize.letter.format!.width, 8.5 * 72);
    expect(PdfPageSize.letter.format!.height, 11 * 72);
    expect(PdfPageSize.original.format, isNull);
  });

  test('presets trade resolution and JPEG quality for size', () {
    expect(PdfQuality.high.targetDpi, isNull);
    expect(PdfQuality.balanced.targetDpi, 200);
    expect(PdfQuality.small.targetDpi, 150);
    expect(
      PdfQuality.values.map((q) => q.jpegQuality),
      orderedEquals([95, 80, 60]),
    );
  });

  test('Original/High keeps the historical 150 DPI page and all pixels', () {
    final p = plan(2480, 3508, PdfPageSize.original, PdfQuality.high);
    expect(p.pageWidth, closeTo(2480 / 150 * 72, 1e-9));
    expect(p.pageHeight, closeTo(3508 / 150 * 72, 1e-9));
    expect((p.imageWidth, p.imageHeight), (p.pageWidth, p.pageHeight));
    expect((p.pixelWidth, p.pixelHeight), (2480, 3508));
    expect(p.nativeDpi, 150);
    expect(p.canvasWidth, isNull);
  });

  test('Original/Balanced keeps the page box but caps the long edge', () {
    final p = plan(2480, 3508, PdfPageSize.original, PdfQuality.balanced);
    expect(p.pageWidth, closeTo(2480 / 150 * 72, 1e-9));
    expect(p.pixelHeight, (200 * 297 / 25.4).round());
    expect(p.pixelWidth / p.pixelHeight, closeTo(2480 / 3508, 0.001));
    // Tesseract's page = pixels / DPI stays close to the same page box.
    expect(p.pixelWidth / p.nativeDpi * 72, closeTo(p.pageWidth, 6));
  });

  test('A4/High fits a 300 DPI scan exactly without resampling', () {
    final p = plan(2480, 3508, PdfPageSize.a4, PdfQuality.high);
    expect(p.pageWidth, PdfPageFormat.a4.width);
    expect(p.pageHeight, PdfPageFormat.a4.height);
    expect((p.pixelWidth, p.pixelHeight), (2480, 3508));
    expect(p.imageWidth, lessThanOrEqualTo(p.pageWidth + 1e-9));
    expect(p.imageHeight, closeTo(p.pageHeight, 1e-6));
    expect(p.nativeDpi, 301);
    // The padded canvas renders as A4 at the native density (within a pixel).
    expect(p.canvasWidth! / p.nativeDpi * 72, closeTo(p.pageWidth, 0.3));
    expect(p.canvasHeight! / p.nativeDpi * 72, closeTo(p.pageHeight, 0.3));
    expect(p.pixelWidth, lessThanOrEqualTo(p.canvasWidth!));
    expect(p.pixelHeight, lessThanOrEqualTo(p.canvasHeight!));
  });

  test('A4/Balanced and Small downscale to their target density', () {
    final balanced = plan(2480, 3508, PdfPageSize.a4, PdfQuality.balanced);
    expect(balanced.nativeDpi, 200);
    expect(balanced.pixelHeight, closeTo(3508 * 200 / 300, 2));
    final small = plan(2480, 3508, PdfPageSize.a4, PdfQuality.small);
    expect(small.nativeDpi, 150);
    expect(small.pixelHeight, closeTo(3508 * 150 / 300, 2));
    expect(small.pageWidth, PdfPageFormat.a4.width);
  });

  test('wide images get a landscape page, centered by aspect ratio', () {
    final p = plan(3000, 1000, PdfPageSize.letter, PdfQuality.high);
    expect(p.pageWidth, PdfPageFormat.letter.height);
    expect(p.pageHeight, PdfPageFormat.letter.width);
    expect(p.imageWidth, closeTo(p.pageWidth, 1e-6));
    expect(p.imageHeight, closeTo(p.pageWidth / 3, 1e-6));
    expect(p.imageHeight, lessThan(p.pageHeight));
  });

  test('small images are never upscaled', () {
    final p = plan(100, 200, PdfPageSize.a4, PdfQuality.small);
    expect((p.pixelWidth, p.pixelHeight), (100, 200));
    // Still drawn to fit the page.
    expect(p.imageHeight, closeTo(PdfPageFormat.a4.height, 1e-6));
  });

  test('the padded canvas stays within the native page-image limits', () {
    final p = plan(8000, 1000, PdfPageSize.a4, PdfQuality.high);
    expect(p.canvasWidth! * p.canvasHeight!, lessThanOrEqualTo(20000000));
    expect(math.max(p.canvasWidth!, p.canvasHeight!), lessThanOrEqualTo(8192));
    expect(p.pixelWidth, lessThanOrEqualTo(p.canvasWidth!));
  });

  test('rejects empty images', () {
    expect(
      () => plan(0, 10, PdfPageSize.a4, PdfQuality.high),
      throwsArgumentError,
    );
  });

  group('preparePdfPage', () {
    PreparedPdfPage prepare(
      Uint8List bytes,
      PdfPageSize size,
      PdfQuality quality, {
      bool pad = false,
    }) => preparePdfPage((
      bytes: bytes,
      pageSize: size,
      quality: quality,
      padToPage: pad,
    ));

    test('keeps JPEG bytes when nothing needs to change', () {
      final jpeg = noisyJpeg(120, 160);
      final original = prepare(jpeg, PdfPageSize.original, PdfQuality.high);
      expect(identical(original.bytes, jpeg), isTrue);
      final a4 = prepare(jpeg, PdfPageSize.a4, PdfQuality.high);
      expect(identical(a4.bytes, jpeg), isTrue);
    });

    test('pads fixed page sizes onto a white canvas for native OCR', () {
      final jpeg = noisyJpeg(120, 160);
      final prepared = prepare(
        jpeg,
        PdfPageSize.a4,
        PdfQuality.high,
        pad: true,
      );
      final decoded = im.decodeJpg(prepared.bytes)!;
      expect(decoded.width, prepared.plan.canvasWidth);
      expect(decoded.height, prepared.plan.canvasHeight);
      final corner = decoded.getPixel(0, 0);
      expect([corner.r, corner.g, corner.b], everyElement(greaterThan(245)));
    });

    test('Small output is markedly smaller and resampled', () {
      // 200 DPI on A4, so Small has to resample it to 150 DPI.
      final jpeg = noisyJpeg(1654, 2339);
      final small = prepare(jpeg, PdfPageSize.a4, PdfQuality.small);
      expect(small.bytes.length, lessThan(jpeg.length ~/ 2));
      final decoded = im.decodeJpg(small.bytes)!;
      expect(decoded.height, small.plan.pixelHeight);
      expect(decoded.height, closeTo(1754, 2));
    });

    test('rejects undecodable data', () {
      expect(
        () => prepare(
          Uint8List.fromList([1, 2, 3]),
          PdfPageSize.a4,
          PdfQuality.high,
        ),
        throwsFormatException,
      );
    });
  });
}
