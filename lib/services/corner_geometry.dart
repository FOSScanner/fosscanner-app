import 'dart:math' as math;
import 'dart:ui';

/// Orders 4 arbitrary document corners clockwise as top-left, top-right,
/// bottom-right, bottom-left.
///
/// Sorting around the centroid avoids the duplicate-corner result produced by
/// the common sum/difference shortcut for symmetric shapes (for example, a
/// document photographed as a diamond). The uppermost edge is used as the top
/// edge, avoiding a 90-degree rotation when perspective makes the bottom-left
/// point farther left than the real top-left point.
///
/// Pure geometry, no native/OpenCV dependency, so it's cheap to unit test
/// directly and safe to use from the web fallback too.
List<Offset> orderCorners(List<Offset> pts) {
  if (pts.length != 4) {
    throw ArgumentError.value(pts, 'pts', 'Exactly four corners are required');
  }
  if (pts.any((p) => !p.dx.isFinite || !p.dy.isFinite) ||
      pts.toSet().length != 4) {
    throw ArgumentError.value(
      pts,
      'pts',
      'Corners must be four distinct finite points',
    );
  }

  final center = pts.reduce((a, b) => a + b) / 4.0;
  final ordered = [...pts]
    ..sort(
      (a, b) => math
          .atan2(a.dy - center.dy, a.dx - center.dx)
          .compareTo(math.atan2(b.dy - center.dy, b.dx - center.dx)),
    );

  var start = 0;
  var topEdgeMidpoint = Offset(
    (ordered[0].dx + ordered[1].dx) / 2,
    (ordered[0].dy + ordered[1].dy) / 2,
  );
  for (var i = 1; i < ordered.length; i++) {
    final next = ordered[(i + 1) % ordered.length];
    final midpoint = Offset(
      (ordered[i].dx + next.dx) / 2,
      (ordered[i].dy + next.dy) / 2,
    );
    if (midpoint.dy < topEdgeMidpoint.dy ||
        (midpoint.dy == topEdgeMidpoint.dy &&
            midpoint.dx > topEdgeMidpoint.dx)) {
      start = i;
      topEdgeMidpoint = midpoint;
    }
  }

  return [for (var i = 0; i < 4; i++) ordered[(start + i) % 4]];
}

double cornerDistance(Offset a, Offset b) => (a - b).distance;

/// Maximum output dimensions for a perspective-corrected page. These prevent
/// hostile crop coordinates from requesting hundreds of megabytes per OpenCV
/// Mat while retaining substantially more than print-A4 resolution for normal
/// scans.
const maxWarpPixels = 9000000;
const maxWarpEdge = 4096;
const maxPreviewWarpPixels = 2000000;
const maxPreviewWarpEdge = 2048;

void _validateConvexQuad(List<Offset> corners) {
  if (corners.length != 4 ||
      corners.any((p) => !p.dx.isFinite || !p.dy.isFinite) ||
      corners.toSet().length != 4) {
    throw ArgumentError.value(
      corners,
      'corners',
      'Four distinct finite corners are required',
    );
  }

  double? winding;
  for (var i = 0; i < corners.length; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % corners.length];
    final c = corners[(i + 2) % corners.length];
    final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    if (!cross.isFinite || cross.abs() < 1e-9) {
      throw ArgumentError.value(
        corners,
        'corners',
        'Corners must form a non-degenerate convex crop',
      );
    }
    winding ??= cross.sign;
    if (cross.sign != winding) {
      throw ArgumentError.value(
        corners,
        'corners',
        'Corners must be consistently wound without crossing edges',
      );
    }
  }
}

// A convex, consistently-wound quad can still have its 4 points in the
// wrong tl/tr/br/bl positions — e.g. two adjacent handles dragged past
// each other, or all 4 roles shifted by one — which looks like a
// perfectly valid crop shape but warps into a flipped/rotated page.
// orderCorners applies the same geometric role assignment used at
// detection time; if it disagrees with the order given here, the corners
// are mislabeled even though the shape itself is fine.
//
// Deliberately separate from _validateConvexQuad (and only ever called
// once, on the caller's original un-rounded corners): orderCorners' choice
// of starting edge is a tie-break on midpoint y that can flip once corners
// are rounded to integers, even when the un-rounded quad was unambiguous.
// Running this same check again against a rounded copy would then reject
// perfectly valid, correctly-labeled crops whenever that tie happened to
// land on opposite sides of the rounding boundary.
void _validateCornerRoles(List<Offset> corners) {
  final canonical = orderCorners(corners);
  for (var i = 0; i < 4; i++) {
    if (canonical[i] != corners[i]) {
      throw ArgumentError.value(
        corners,
        'corners',
        'Corners must be ordered top-left, top-right, bottom-right, bottom-left',
      );
    }
  }
}

/// Calculates a bounded output size from ordered document [corners], preserving
/// the selected crop's aspect ratio when it must be downscaled.
(int width, int height) calculateWarpSize(
  List<Offset> corners, {
  int maxPixels = maxWarpPixels,
  int maxEdge = maxWarpEdge,
}) {
  if (maxPixels < 4 || maxEdge < 2) {
    throw ArgumentError('Warp limits must allow an image of at least 2×2');
  }
  _validateConvexQuad(corners);
  _validateCornerRoles(corners);

  // OpenCV receives integer source points. Validate and size from those exact
  // points so a valid-looking fractional quad cannot collapse when converted.
  final roundedCorners = [
    for (final p in corners) Offset(p.dx.roundToDouble(), p.dy.roundToDouble()),
  ];
  _validateConvexQuad(roundedCorners);

  final tl = roundedCorners[0],
      tr = roundedCorners[1],
      br = roundedCorners[2],
      bl = roundedCorners[3];
  final rawWidth = math
      .max(cornerDistance(tl, tr), cornerDistance(bl, br))
      .roundToDouble();
  final rawHeight = math
      .max(cornerDistance(tl, bl), cornerDistance(tr, br))
      .roundToDouble();
  if (!rawWidth.isFinite ||
      !rawHeight.isFinite ||
      rawWidth < 2 ||
      rawHeight < 2) {
    throw ArgumentError.value(
      corners,
      'corners',
      'Crop output edges must be finite and at least two pixels',
    );
  }

  // Keep calculations in double space until after scaling. Clamping either
  // raw edge independently would turn extreme panoramas into near-squares.
  // Dividing the square roots avoids overflowing rawWidth * rawHeight.
  final pixelScale =
      math.sqrt(maxPixels) / math.sqrt(rawWidth) / math.sqrt(rawHeight);
  final scale = math.min(
    1.0,
    math.min(maxEdge / math.max(rawWidth, rawHeight), pixelScale),
  );
  final scaledWidth = rawWidth * scale;
  final scaledHeight = rawHeight * scale;
  if (scaledWidth < 2 || scaledHeight < 2) {
    throw ArgumentError.value(
      corners,
      'corners',
      'Crop aspect ratio is too extreme for the bounded output size',
    );
  }

  var outputWidth = scaledWidth.round();
  var outputHeight = scaledHeight.round();
  if (outputWidth * outputHeight > maxPixels) {
    final correction = math.sqrt(maxPixels / (outputWidth * outputHeight));
    outputWidth = math.max(2, (outputWidth * correction).floor());
    outputHeight = math.max(2, (outputHeight * correction).floor());
  }
  return (outputWidth, outputHeight);
}
