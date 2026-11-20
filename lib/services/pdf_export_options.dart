import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart' show PdfPageFormat;

import 'image_metadata.dart' show maxSourceImageEdge, maxSourceImagePixels;

/// Density assumed for pages exported at their original size.
///
/// Photos carry no physical size, so "Original" pages have always been sized
/// as if scanned at this density. Keep it unchanged so existing exports keep
/// their page dimensions. Pages with a known source density (rendered from an
/// imported PDF) use that instead; see [planPdfPage].
const originalPageDpi = 150.0;

/// The page box of an exported PDF.
enum PdfPageSize {
  /// One page per image, sized from its pixels at the page's source density,
  /// or at [originalPageDpi] when it has none.
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
/// "Original" sizes the page from its pixels at [sourceDpi], the density the
/// image was rendered at when it came from a PDF, or at [originalPageDpi]
/// for photos; its image is only resampled when a preset's density is below
/// that, so every
/// preset keeps its "up to N DPI" promise on the actual page. A4 and Letter
/// fit the whole image inside the page, centered, with the page turned to
/// landscape for landscape images, and cap the image at the preset's DPI.
/// Images are never upscaled.
///
/// The page box is exactly what a pixels / DPI renderer (Tesseract) produces
/// from the plan, so image-only and searchable exports get identical pages.
/// For A4 and Letter the integer density is chosen among a few neighbours to
/// keep that box as close as possible to the standard size (Letter exactly).
PdfPagePlan planPdfPage({
  required int sourceWidth,
  required int sourceHeight,
  required PdfPageSize pageSize,
  required PdfQuality quality,
  double? sourceDpi,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    throw ArgumentError('Page images need a positive size');
  }
  final targetDpi = quality.targetDpi;
  final format = pageSize.format;
  if (format == null) {
    final density = originalDensity(sourceDpi);
    final keepsPixels = targetDpi == null || targetDpi >= density;
    final nativeDpi = keepsPixels ? density : targetDpi;
    final scale = keepsPixels ? 1.0 : targetDpi / density;
    final pixelWidth = math.max(1, (sourceWidth * scale).round());
    final pixelHeight = math.max(1, (sourceHeight * scale).round());
    final pageWidth = pixelWidth * PdfPageFormat.inch / nativeDpi;
    final pageHeight = pixelHeight * PdfPageFormat.inch / nativeDpi;
    return PdfPagePlan(
      pageWidth: pageWidth,
      pageHeight: pageHeight,
      imageWidth: pageWidth,
      imageHeight: pageHeight,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      nativeDpi: nativeDpi,
    );
  }

  final landscape = sourceWidth > sourceHeight;
  final formatWidth = landscape ? format.height : format.width;
  final formatHeight = landscape ? format.width : format.height;
  final pageWidthInches = formatWidth / PdfPageFormat.inch;
  final pageHeightInches = formatHeight / PdfPageFormat.inch;
  // The density at which the unscaled image exactly fits the page.
  final fitDpi = math.max(
    sourceWidth / pageWidthInches,
    sourceHeight / pageHeightInches,
  );
  // A padded canvas must stay within the native renderer's page-image limits,
  // which caps the density even at High (about 450 DPI on A4).
  final maxCanvasDpi = math.max(
    1,
    math
        .min(
          maxSourceImageEdge / math.max(pageWidthInches, pageHeightInches),
          math.sqrt(
            maxSourceImagePixels / (pageWidthInches * pageHeightInches),
          ),
        )
        .floor(),
  );
  final capDpi = targetDpi == null
      ? maxCanvasDpi
      : math.min(maxCanvasDpi, targetDpi);
  // Below the cap the image keeps all its pixels at any density from the
  // fit density up; above it, densities just under the cap are allowed.
  final keepsPixels = fitDpi <= capDpi;
  final preferredDpi = keepsPixels ? math.max(1, fitDpi.ceil()) : capDpi;
  final candidates = keepsPixels
      ? [
          for (
            var dpi = preferredDpi;
            dpi <= math.min(capDpi, preferredDpi + _dpiSearchSpan);
            dpi++
          )
            dpi,
        ]
      : [
          for (
            var dpi = preferredDpi;
            dpi >= math.max(1, preferredDpi - _dpiSearchSpan);
            dpi--
          )
            dpi,
        ];
  double drift(int dpi) =>
      ((pageWidthInches * dpi).round() / dpi - pageWidthInches).abs() +
      ((pageHeightInches * dpi).round() / dpi - pageHeightInches).abs();
  var nativeDpi = candidates.first;
  for (final dpi in candidates.skip(1)) {
    // Only switch for a clearly smaller drift, so the preferred density wins
    // whenever neighbours are about as good.
    if (drift(dpi) < drift(nativeDpi) - 1e-9) nativeDpi = dpi;
  }
  final canvasWidth = math.max(1, (pageWidthInches * nativeDpi).round());
  final canvasHeight = math.max(1, (pageHeightInches * nativeDpi).round());
  final scale = keepsPixels ? 1.0 : nativeDpi / fitDpi;
  final pixelWidth = math.min(
    canvasWidth,
    math.max(1, (sourceWidth * scale).round()),
  );
  final pixelHeight = math.min(
    canvasHeight,
    math.max(1, (sourceHeight * scale).round()),
  );
  final pageWidth = canvasWidth * PdfPageFormat.inch / nativeDpi;
  final pageHeight = canvasHeight * PdfPageFormat.inch / nativeDpi;
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

/// The integer density an "Original" page of [sourceDpi] is sized at.
///
/// Integer because renderers that size pages as pixels / DPI (Tesseract)
/// take whole densities; image-only exports use the same value so both
/// produce identical pages. Rounding moves a page by under half a percent.
int originalDensity(double? sourceDpi) {
  final dpi = sourceDpi;
  if (dpi == null || !dpi.isFinite || dpi < 1) return originalPageDpi.round();
  return math.max(1, dpi.round());
}

/// How far the planner may move the integer density to keep fixed page
/// boxes close to their standard size.
const _dpiSearchSpan = 3;

/// One page ready for a PDF writer.
typedef PreparedPdfPage = ({Uint8List bytes, PdfPagePlan plan});

/// Arguments for [preparePdfPage]; a record so it can cross to a worker.
typedef PdfPageJob = ({
  Uint8List bytes,
  PdfPageSize pageSize,
  PdfQuality quality,
  bool padToPage,
  double? sourceDpi,
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
    sourceDpi: job.sourceDpi,
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
