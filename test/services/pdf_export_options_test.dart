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

  test('Original keeps the page box and honours every preset density', () {
    // A tall receipt-like page: taller than A4, so a cap derived from A4
    // would push Small below its promised 150 DPI.
    for (final source in [(2480, 3508), (804, 2181), (300, 120)]) {
      for (final quality in PdfQuality.values) {
        final p = plan(source.$1, source.$2, PdfPageSize.original, quality);
        expect(p.pageWidth, closeTo(source.$1 / 150 * 72, 1e-9));
        expect(p.pageHeight, closeTo(source.$2 / 150 * 72, 1e-9));
        expect((p.pixelWidth, p.pixelHeight), source);
        expect(p.nativeDpi, 150);
        final density = p.pixelHeight / (p.pageHeight / 72);
        expect(density, closeTo(150, 1e-9));
        expect(density, lessThanOrEqualTo(quality.targetDpi ?? 150));
      }
    }
  });

  test('A4/High fits a 300 DPI scan without resampling', () {
    final p = plan(2480, 3508, PdfPageSize.a4, PdfQuality.high);
    expect(p.pageWidth, closeTo(PdfPageFormat.a4.width, 0.1));
    expect(p.pageHeight, closeTo(PdfPageFormat.a4.height, 0.1));
    expect((p.pixelWidth, p.pixelHeight), (2480, 3508));
    expect(p.imageWidth, lessThanOrEqualTo(p.pageWidth + 1e-9));
    expect(p.imageHeight, closeTo(p.pageHeight, 0.1));
    expect(p.nativeDpi, inInclusiveRange(301, 304));
    expect(p.pixelWidth, lessThanOrEqualTo(p.canvasWidth!));
    expect(p.pixelHeight, lessThanOrEqualTo(p.canvasHeight!));
  });

  test('A4/Balanced and Small downscale to their target density', () {
    final balanced = plan(2480, 3508, PdfPageSize.a4, PdfQuality.balanced);
    expect(balanced.nativeDpi, inInclusiveRange(197, 200));
    expect(balanced.pixelHeight, closeTo(3508 * balanced.nativeDpi / 300, 2));
    final small = plan(2480, 3508, PdfPageSize.a4, PdfQuality.small);
    expect(small.nativeDpi, inInclusiveRange(147, 150));
    expect(small.pixelHeight, closeTo(3508 * small.nativeDpi / 300, 2));
    expect(small.pageWidth, closeTo(PdfPageFormat.a4.width, 0.1));
  });

  group('page boxes match a pixels / DPI renderer exactly', () {
    const sources = [
      (2480, 3508),
      (3508, 2480),
      (3024, 4032),
      (1700, 2200),
      (1653, 2339),
      (804, 2181),
      (4000, 3000),
      (1240, 1754),
    ];
    for (final size in PdfPageSize.values) {
      for (final quality in PdfQuality.values) {
        test('${size.label} / ${quality.label}', () {
          for (final (w, h) in sources) {
            final p = plan(w, h, size, quality);
            // What Tesseract's renderer writes: page = image pixels * 72 / DPI,
            // where the image is the padded canvas for fixed sizes.
            final rendererWidth =
                (p.canvasWidth ?? p.pixelWidth) * 72.0 / p.nativeDpi;
            final rendererHeight =
                (p.canvasHeight ?? p.pixelHeight) * 72.0 / p.nativeDpi;
            expect(p.pageWidth, rendererWidth, reason: '$w x $h');
            expect(p.pageHeight, rendererHeight, reason: '$w x $h');
            final format = size.format;
            if (format == null) continue;
            final landscape = w > h;
            final expectedWidth = landscape ? format.height : format.width;
            final expectedHeight = landscape ? format.width : format.height;
            if (size == PdfPageSize.letter) {
              expect(
                (p.pageWidth, p.pageHeight),
                (expectedWidth, expectedHeight),
              );
            } else {
              // Within a fraction of a canvas pixel of the standard size.
              expect(p.pageWidth, closeTo(expectedWidth, 0.25));
              expect(p.pageHeight, closeTo(expectedHeight, 0.25));
            }
            // Never above the promised density, never upscaled.
            final target = quality.targetDpi;
            if (target != null) {
              expect(p.nativeDpi, lessThanOrEqualTo(target));
            }
            expect(p.pixelWidth, lessThanOrEqualTo(w));
            expect(p.pixelHeight, lessThanOrEqualTo(h));
          }
        });
      }
    }
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
    // Still drawn to fit the page, within one canvas pixel.
    expect(p.imageHeight, closeTo(PdfPageFormat.a4.height, 72 / p.nativeDpi));
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
