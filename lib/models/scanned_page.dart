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
  });

  /// The untouched captured photo. Kept so corners/filter can be redone
  /// later (Phase 3: re-edit) without re-capturing.
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

  ScannedPage copyWith({
    List<Offset>? corners,
    PageFilter? filter,
    int? rotationQuarterTurns,
    double? brightness,
    double? contrast,
    Uint8List? processedBytes,
  }) {
    return ScannedPage(
      originalBytes: originalBytes,
      corners: corners ?? this.corners,
      filter: filter ?? this.filter,
      rotationQuarterTurns: rotationQuarterTurns ?? this.rotationQuarterTurns,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      processedBytes: processedBytes ?? this.processedBytes,
    );
  }
}
