import 'dart:typed_data';
import 'dart:ui';

/// Visual treatment applied to a scanned page before it's exported.
enum PageFilter {
  /// Warped color image, no further processing.
  original,

  /// Contrast/brightness normalized, closer to the "Magic Color" look of
  /// most scanner apps.
  autoEnhance,

  /// Converted to grayscale.
  grayscale,

  /// Grayscale + adaptive threshold: the classic black-and-white scanned
  /// page look.
  blackAndWhite,
}

/// A single captured page, from the raw photo through to the
/// perspective-corrected, filtered result that actually goes in the PDF.
class ScannedPage {
  ScannedPage({
    required this.originalBytes,
    required this.corners,
    required this.processedBytes,
    this.filter = PageFilter.original,
    this.rotationQuarterTurns = 0,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.sourceDpi,
  });

  /// The untouched captured photo. Kept so corners, filters, and adjustments
  /// can be changed later without re-capturing.
  final Uint8List originalBytes;

  /// The 4 document corners in `originalBytes`' pixel space, ordered
  /// top-left, top-right, bottom-right, bottom-left.
  final List<Offset> corners;

  /// The chosen filter, already baked into [processedBytes].
  final PageFilter filter;

  /// Clockwise quarter-turns applied on top of the filter, already baked
  /// into [processedBytes]. Kept (rather than only baking it in) so
  /// re-editing this page can restore it instead of silently losing it.
  final int rotationQuarterTurns;

  /// Brightness/contrast adjustment applied on top of the filter, already
  /// baked into [processedBytes]. Same reason as [rotationQuarterTurns]:
  /// kept so re-edit can restore it.
  final double brightness;
  final double contrast;

  /// Perspective-corrected + filtered image, ready for the thumbnail grid
  /// and PDF export.
  final Uint8List processedBytes;

  /// Pixels per inch of [originalBytes] when its physical size is known, as
  /// for pages rendered from an imported PDF; null for photos. The "Original"
  /// PDF page size uses it so imported pages keep their real size.
  final double? sourceDpi;

  /// This page with [sourceDpi] set to [dpi]; the page itself when equal.
  ScannedPage withSourceDpi(double? dpi) => dpi == sourceDpi
      ? this
      : ScannedPage(
          originalBytes: originalBytes,
          corners: corners,
          processedBytes: processedBytes,
          filter: filter,
          rotationQuarterTurns: rotationQuarterTurns,
          brightness: brightness,
          contrast: contrast,
          sourceDpi: dpi,
        );
}

/// Lowest and highest source density a page may record, matching the PDF
/// import's render range with room for pages rendered below it.
const minSourceDpi = 1.0;
const maxSourceDpi = 1200.0;

/// [value] as a source density, or null when it is not a usable one.
double? validSourceDpi(Object? value) {
  if (value is! num) return null;
  final dpi = value.toDouble();
  return dpi.isFinite && dpi >= minSourceDpi && dpi <= maxSourceDpi
      ? dpi
      : null;
}
