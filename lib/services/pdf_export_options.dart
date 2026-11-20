import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart' show PdfPageFormat;

import 'image_metadata.dart' show maxSourceImageEdge, maxSourceImagePixels;

/// Density assumed for pages exported at their original size.
///
/// Scanner pages carry no physical size, so "Original" pages have always been
/// sized as if scanned at this density. Keep it unchanged so existing exports
/// keep their page dimensions.
const originalPageDpi = 150.0;

/// The page box of an exported PDF.
enum PdfPageSize {
  /// One page per image, sized from its pixels at [originalPageDpi].
  original('Original'),

  /// ISO A4, oriented to match each page image.
  a4('A4'),

  /// US Letter, oriented to match each page image.
  letter('Letter');

  const PdfPageSize(this.label);

  final String label;

  /// Portrait page dimensions in PDF points, or null for [original].
  PdfPageFormat? get format => switch (this) {
    original => null,
    a4 => PdfPageFormat.a4,
    letter => PdfPageFormat.letter,
  };
}

/// Trade-off between image fidelity and file size.
enum PdfQuality {
  /// Full resolution; JPEG pages are embedded without another lossy encode.
  high('High', targetDpi: null, jpegQuality: 95),

  /// Readable prints and reliable text recognition at about half the size.
  balanced('Balanced', targetDpi: 200, jpegQuality: 80),

  /// For mail and upload limits; fine print may lose detail.
  small('Small', targetDpi: 150, jpegQuality: 60);

  const PdfQuality(
    this.label, {
    required this.targetDpi,
    required this.jpegQuality,
  });

  final String label;

  /// Maximum image density on the exported page, or null for no limit.
  final int? targetDpi;

  /// JPEG quality used whenever a page has to be encoded.
  final int jpegQuality;
}

/// Long edge of the reference page used to cap "Original" pages, whose
/// physical size is nominal: A4's long edge, in inches.
const _referenceLongEdgeInches = 297 / 25.4;

/// How one page image is placed on its PDF page.
class PdfPagePlan {
  const PdfPagePlan({
    required this.pageWidth,
    required this.pageHeight,
    required this.imageWidth,
    required this.imageHeight,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.nativeDpi,
    this.canvasWidth,
    this.canvasHeight,
  });

  /// Page box in PDF points.
  final double pageWidth;
  final double pageHeight;

  /// Size of the centered image on the page, in PDF points.
  final double imageWidth;
  final double imageHeight;

  /// Pixel size the page image is resampled to (never larger than source).
  final int pixelWidth;
  final int pixelHeight;

  /// Integer density for renderers that size pages as pixels / DPI, such as
  /// Tesseract's PDF renderer.
  final int nativeDpi;

  /// For fixed page sizes, the white canvas (in pixels at [nativeDpi]) the
  /// image is centered on so a pixels / DPI renderer produces the page box.
  final int? canvasWidth;
  final int? canvasHeight;

  @override
  String toString() =>
      'PdfPagePlan(page: ${pageWidth}x$pageHeight pt, '
      'image: ${imageWidth}x$imageHeight pt, '
      'pixels: ${pixelWidth}x$pixelHeight, dpi: $nativeDpi, '
      'canvas: ${canvasWidth}x$canvasHeight)';
}

/// Plans how a [sourceWidth] x [sourceHeight] page image is exported.
///
/// "Original" keeps today's page size (pixels at [originalPageDpi]) and caps
/// the image's long edge at the preset's DPI over an A4 long edge. A4 and
/// Letter fit the whole image inside the page, centered, with the page turned
/// to landscape for landscape images, and cap the image at the preset's DPI.
/// Images are never upscaled.
PdfPagePlan planPdfPage({
  required int sourceWidth,
  required int sourceHeight,
  required PdfPageSize pageSize,
  required PdfQuality quality,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    throw ArgumentError('Page images need a positive size');
  }
  final targetDpi = quality.targetDpi;
  final format = pageSize.format;
  if (format == null) {
    final longEdge = math.max(sourceWidth, sourceHeight);
    final scale = targetDpi == null
        ? 1.0
        : math.min(1.0, targetDpi * _referenceLongEdgeInches / longEdge);
    final pixelWidth = math.max(1, (sourceWidth * scale).round());
    final pixelHeight = math.max(1, (sourceHeight * scale).round());
    final pageWidth = sourceWidth / originalPageDpi * PdfPageFormat.inch;
    final pageHeight = sourceHeight / originalPageDpi * PdfPageFormat.inch;
    return PdfPagePlan(
      pageWidth: pageWidth,
      pageHeight: pageHeight,
      imageWidth: pageWidth,
      imageHeight: pageHeight,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      nativeDpi: math.max(
        1,
        (originalPageDpi * pixelWidth / sourceWidth).round(),
      ),
    );
  }

  final landscape = sourceWidth > sourceHeight;
  final pageWidth = landscape ? format.height : format.width;
  final pageHeight = landscape ? format.width : format.height;
  final pageWidthInches = pageWidth / PdfPageFormat.inch;
  final pageHeightInches = pageHeight / PdfPageFormat.inch;
  // The density at which the unscaled image exactly fits the page.
  final fitDpi = math.max(
    sourceWidth / pageWidthInches,
    sourceHeight / pageHeightInches,
  );
  // A padded canvas must stay within the native renderer's page-image limits,
  // which caps the density even at High (about 450 DPI on A4).
  final maxCanvasDpi = math
      .min(
        maxSourceImageEdge / math.max(pageWidthInches, pageHeightInches),
        math.sqrt(maxSourceImagePixels / (pageWidthInches * pageHeightInches)),
      )
      .floorToDouble();
  final dpi = math.min(
    maxCanvasDpi,
    targetDpi == null ? fitDpi : math.min(fitDpi, targetDpi * 1.0),
  );
  final nativeDpi = math.max(
    1,
    math.min(maxCanvasDpi, dpi.ceilToDouble()).toInt(),
  );
  final canvasWidth = math.max(1, (pageWidthInches * nativeDpi).round());
  final canvasHeight = math.max(1, (pageHeightInches * nativeDpi).round());
  final scale = math.min(1.0, dpi / fitDpi);
  final pixelWidth = math.min(
    canvasWidth,
    math.max(1, (sourceWidth * scale).round()),
  );
  final pixelHeight = math.min(
    canvasHeight,
    math.max(1, (sourceHeight * scale).round()),
  );
  return PdfPagePlan(
    pageWidth: pageWidth,
    pageHeight: pageHeight,
    imageWidth: math.min(pageWidth, sourceWidth / fitDpi * PdfPageFormat.inch),
    imageHeight: math.min(
      pageHeight,
      sourceHeight / fitDpi * PdfPageFormat.inch,
    ),
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    nativeDpi: nativeDpi,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
  );
}

/// One page ready for a PDF writer.
typedef PreparedPdfPage = ({Uint8List bytes, PdfPagePlan plan});

/// Arguments for [preparePdfPage]; a record so it can cross to a worker.
typedef PdfPageJob = ({
  Uint8List bytes,
  PdfPageSize pageSize,
  PdfQuality quality,
  bool padToPage,
});

/// Resamples and encodes one page image according to its [PdfPagePlan].
///
/// Run it on a worker: it may decode a full page. With `padToPage`, fixed page
/// sizes center the image on a white canvas so renderers that size pages from
/// pixels (Tesseract) produce the right page box. JPEG pages that need no
/// resampling keep their bytes at [PdfQuality.high], and keep them at other
/// presets too when re-encoding would not make them smaller.
PreparedPdfPage preparePdfPage(PdfPageJob job) {
  final bytes = job.bytes;
  final decoder = im.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (decoder == null || info == null) {
    throw const FormatException('Could not decode PDF page');
  }
  final plan = planPdfPage(
    sourceWidth: info.width,
    sourceHeight: info.height,
    pageSize: job.pageSize,
    quality: job.quality,
  );
  final isJpeg = decoder is im.JpegDecoder;
  final resamples =
      plan.pixelWidth != info.width || plan.pixelHeight != info.height;
  final pads = job.padToPage && plan.canvasWidth != null;
  final recompresses = job.quality != PdfQuality.high;
  if (isJpeg && !resamples && !pads && !recompresses) {
    return (bytes: bytes, plan: plan);
  }

  final decoded = decoder.decode(bytes, frame: 0);
  if (decoded == null) throw const FormatException('Could not decode PDF page');
  var image = resamples
      ? im.copyResize(
          decoded,
          width: plan.pixelWidth,
          height: plan.pixelHeight,
          interpolation: im.Interpolation.average,
        )
      : decoded;
  if (pads || image.hasAlpha) {
    final canvas = im.Image(
      width: pads ? plan.canvasWidth! : image.width,
      height: pads ? plan.canvasHeight! : image.height,
      numChannels: 3,
    );
    // Flattens transparency onto white and, when padding, fills the margins.
    im.fill(canvas, color: im.ColorRgb8(255, 255, 255));
    im.compositeImage(
      canvas,
      image,
      dstX: (canvas.width - image.width) ~/ 2,
      dstY: (canvas.height - image.height) ~/ 2,
    );
    image = canvas;
  }
  final encoded = im.encodeJpg(image, quality: job.quality.jpegQuality);
  if (isJpeg && !resamples && !pads && encoded.length >= bytes.length) {
    return (bytes: bytes, plan: plan);
  }
  return (bytes: encoded, plan: plan);
}
