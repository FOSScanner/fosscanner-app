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
/// directly and safe to use from mobile code too.
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

/// Why a crop cannot be previewed, in terms the user can fix by dragging.
enum CropProblem {
  /// Two edges of the quad intersect (a bow-tie).
  cornersCross,

  /// One corner lies inside the triangle formed by the other three.
  cornerInside,

  /// The crop is too small to be a page: its width, height or area is
  /// below [minCropFraction] of the image, however well shaped.
  areaTooSmall,

  /// The crop is spread out but has (almost) no shape: corners on top of
  /// each other, three in a line, or three bunched together.
  cornersInLine,
}

/// The smallest crop accepted, as a fraction of the image's shorter side:
/// both crop dimensions must reach it and the area must reach its square.
/// Anything smaller is a handful of pixels, not a page (for example four
/// corners dragged into one clump on a plain page).
const minCropFraction = 0.08;

/// Corners closer to a straight line than this (the sine of the angle at a
/// corner) are treated as collinear: the crop would be a triangle.
const _minCornerSine = 0.05;

/// Returns [corners] re-ordered clockwise from top-left when the four points
/// form a convex quad in some order (for example after one handle was dragged
/// past its neighbour). Anything else is returned unchanged: there is no
/// single right order for a concave or degenerate set of points.
List<Offset> sortCornersIfConvex(List<Offset> corners) {
  final List<Offset> ordered;
  try {
    ordered = orderCorners(corners);
    _validateConvexQuad(ordered);
  } on ArgumentError {
    return corners;
  }
  return ordered;
}

bool _segmentsCross(Offset a, Offset b, Offset c, Offset d) {
  double side(Offset p, Offset q, Offset r) =>
      (q.dx - p.dx) * (r.dy - p.dy) - (q.dy - p.dy) * (r.dx - p.dx);
  final d1 = side(c, d, a);
  final d2 = side(c, d, b);
  final d3 = side(a, b, c);
  final d4 = side(a, b, d);
  return d1 * d2 < 0 && d3 * d4 < 0;
}

/// Checks [corners] against the same bounded-preview rules the warp uses,
/// plus a minimum size relative to [imageSize], and returns the reason they
/// are rejected, or null for a valid crop.
CropProblem? cropProblem(List<Offset> corners, {required Size imageSize}) {
  if (corners.length != 4 ||
      corners.any((p) => !p.dx.isFinite || !p.dy.isFinite)) {
    return CropProblem.areaTooSmall;
  }
  final minSide = minCropFraction * imageSize.shortestSide;
  // A clump is too small whatever its shape: dragging one corner out
  // would only turn it into another problem.
  if (_longestDistance(corners) < minSide) return CropProblem.areaTooSmall;

  try {
    calculateWarpSize(
      corners,
      maxPixels: maxPreviewWarpPixels,
      maxEdge: maxPreviewWarpEdge,
    );
  } on ArgumentError {
    if (corners.toSet().length != 4) return CropProblem.cornersInLine;
    if (_segmentsCross(corners[0], corners[1], corners[2], corners[3]) ||
        _segmentsCross(corners[1], corners[2], corners[3], corners[0])) {
      return CropProblem.cornersCross;
    }
    if (_isCollapsed(corners) || _hasStraightCorner(corners)) {
      return CropProblem.cornersInLine;
    }
    double? winding;
    for (var i = 0; i < 4; i++) {
      final cross = _turn(
        corners[i],
        corners[(i + 1) % 4],
        corners[(i + 2) % 4],
      );
      winding ??= cross.sign;
      if (cross.sign != winding) return CropProblem.cornerInside;
    }
    // Convex but too thin, or convex with mislabelled corners; the editor
    // re-sorts the latter, so what remains is a sliver.
    return CropProblem.areaTooSmall;
  }

  // A valid quad: still reject a crop with a corner on the line between
  // its neighbours (a triangle), or one too small to be a page.
  if (_hasStraightCorner(corners)) return CropProblem.cornersInLine;
  final width = math.max(
    cornerDistance(corners[0], corners[1]),
    cornerDistance(corners[3], corners[2]),
  );
  final height = math.max(
    cornerDistance(corners[0], corners[3]),
    cornerDistance(corners[1], corners[2]),
  );
  if (width < minSide ||
      height < minSide ||
      _area(corners) < minSide * minSide) {
    return CropProblem.areaTooSmall;
  }
  return null;
}

/// Twice the signed area of triangle [a], [b], [c]: positive for one turn
/// direction, negative for the other, zero when they are collinear.
double _turn(Offset a, Offset b, Offset c) =>
    (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);

/// Whether the angle at some corner is (almost) straight, so that corner
/// lies on the line between its neighbours.
bool _hasStraightCorner(List<Offset> corners) {
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    final c = corners[(i + 2) % 4];
    final lengths = (b - a).distance * (c - b).distance;
    if (lengths == 0 || _turn(a, b, c).abs() / lengths < _minCornerSine) {
      return true;
    }
  }
  return false;
}

double _area(List<Offset> corners) {
  var doubleArea = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    doubleArea += a.dx * b.dy - b.dx * a.dy;
  }
  return doubleArea.abs() / 2;
}

double _longestDistance(List<Offset> corners) {
  var longest = 0.0;
  for (var i = 0; i < 4; i++) {
    for (var j = i + 1; j < 4; j++) {
      longest = math.max(longest, (corners[i] - corners[j]).distance);
    }
  }
  return longest;
}

/// Whether an invalid quad has (nearly) collapsed: three corners bunched
/// together, two pairs of corners on top of each other, or almost no area
/// for how far the corners spread. Moving the corners apart fixes it.
bool _isCollapsed(List<Offset> corners) {
  final longest = _longestDistance(corners);
  if (longest == 0) return true;
  var closePairs = 0;
  for (var i = 0; i < 4; i++) {
    for (var j = i + 1; j < 4; j++) {
      if ((corners[i] - corners[j]).distance < 0.15 * longest) closePairs++;
    }
  }
  return closePairs >= 2 || _area(corners) < 0.02 * longest * longest;
}
