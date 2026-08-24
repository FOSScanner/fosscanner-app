import 'dart:typed_data';
import 'dart:ui';

import '../models/scanned_page.dart';
import 'corner_geometry.dart';

/// `opencv_dart` doesn't support web (it's FFI-based). On web we skip
/// detection/warping entirely and fall back to the page as captured —
/// web is a preview/testing target only, native builds are the real
/// target for this feature.
List<Offset>? detectCorners(Uint8List imageBytes) => null;

Uint8List warpDocument(
  Uint8List imageBytes,
  List<Offset> corners, {
  int maxPixels = maxWarpPixels,
  int maxEdge = maxWarpEdge,
}) {
  calculateWarpSize(corners, maxPixels: maxPixels, maxEdge: maxEdge);
  return imageBytes;
}

Uint8List applyFilter(Uint8List warpedBytes, PageFilter filter) => warpedBytes;

Uint8List rotateImage(Uint8List imageBytes, int quarterTurns) => imageBytes;

Uint8List adjustBrightnessContrast(
  Uint8List imageBytes, {
  required double brightness,
  required double contrast,
}) => imageBytes;

Uint8List processDocument(
  Uint8List imageBytes,
  List<Offset> corners, {
  required PageFilter filter,
  required int rotationQuarterTurns,
  required double brightness,
  required double contrast,
}) {
  calculateWarpSize(corners);
  return imageBytes;
}
