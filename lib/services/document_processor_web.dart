import 'dart:typed_data';
import 'dart:ui';

import '../models/scanned_page.dart';

/// `opencv_dart` doesn't support web (it's FFI-based). On web we skip
/// detection/warping entirely and fall back to the page as captured —
/// web is a preview/testing target only, native builds are the real
/// target for this feature.
List<Offset>? detectCorners(Uint8List imageBytes) => null;

Uint8List warpDocument(Uint8List imageBytes, List<Offset> corners) => imageBytes;

Uint8List applyFilter(Uint8List warpedBytes, PageFilter filter) => warpedBytes;

Uint8List rotateImage(Uint8List imageBytes, int quarterTurns) => imageBytes;

Uint8List adjustBrightnessContrast(
  Uint8List imageBytes, {
  required double brightness,
  required double contrast,
}) =>
    imageBytes;
