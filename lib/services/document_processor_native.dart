import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../models/scanned_page.dart';
import 'corner_geometry.dart';

/// Long edge (px) images are downscaled to before edge detection. Detection
/// only needs to find corner *positions*, which are then scaled back up to
/// the original resolution — running Canny/contours on a full-size camera
/// photo would be needlessly slow.
const _maxDetectionEdge = 1000.0;

/// Attempts to find a document quad in [imageBytes]. Returns null if
/// nothing suitable is found (caller should fall back to corners at the
/// image bounds for manual placement).
List<Offset>? detectCorners(Uint8List imageBytes) {
  final mats = <cv.Mat>[];
  cv.Mat track(cv.Mat m) {
    mats.add(m);
    return m;
  }

  try {
    final src = track(cv.imdecode(imageBytes, cv.IMREAD_COLOR));
    final longEdge = math.max(src.cols, src.rows);
    final scale = longEdge > _maxDetectionEdge ? _maxDetectionEdge / longEdge : 1.0;
    final small = track(
      scale < 1.0 ? cv.resize(src, (0, 0), fx: scale, fy: scale) : src.clone(),
    );
    final gray = track(cv.cvtColor(small, cv.COLOR_BGR2GRAY));
    final blurred = track(cv.gaussianBlur(gray, (5, 5), 0));
    final edges = track(cv.canny(blurred, 50, 150));
    final dilated = track(
      cv.dilate(edges, cv.getStructuringElement(cv.MORPH_RECT, (3, 3))),
    );

    final (contours, _) = cv.findContours(dilated, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    try {
      final quad = _findDocumentQuad(contours, small.cols * small.rows);
      if (quad == null) return null;

      final invScale = 1.0 / scale;
      final scaledCorners = quad.map((p) => Offset(p.x * invScale, p.y * invScale)).toList();
      return orderCorners(scaledCorners);
    } finally {
      for (final c in contours) {
        c.dispose();
      }
    }
  } finally {
    for (final m in mats) {
      m.dispose();
    }
  }
}

/// Finds the largest contour that simplifies to a 4-point polygon covering
/// a reasonable fraction of the image, sweeping the approxPolyDP epsilon
/// upward until one does (a single fixed epsilon is too brittle against
/// real-world edge noise).
List<cv.Point>? _findDocumentQuad(cv.VecVecPoint contours, int imageArea) {
  final areas = <(int, double)>[];
  for (var i = 0; i < contours.length; i++) {
    areas.add((i, cv.contourArea(contours[i])));
  }
  areas.sort((a, b) => b.$2.compareTo(a.$2));

  for (final (idx, area) in areas.take(5)) {
    if (area < imageArea * 0.15) continue;
    final c = contours[idx];
    final peri = cv.arcLength(c, true);
    for (final frac in [0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.1]) {
      final approx = cv.approxPolyDP(c, frac * peri, true);
      if (approx.length == 4) return approx.toList();
    }
  }
  return null;
}

/// Perspective-corrects [imageBytes] using [corners] (top-left, top-right,
/// bottom-right, bottom-left, in the image's pixel space), producing a
/// flattened, upright JPEG. Output size is derived from the corners' side
/// lengths so the result keeps the document's real proportions.
Uint8List warpDocument(Uint8List imageBytes, List<Offset> corners) {
  assert(corners.length == 4);
  final mats = <cv.Mat>[];
  cv.Mat track(cv.Mat m) {
    mats.add(m);
    return m;
  }

  try {
    final src = track(cv.imdecode(imageBytes, cv.IMREAD_COLOR));
    final tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3];

    final outW = math.max(cornerDistance(tl, tr), cornerDistance(bl, br)).round().clamp(1, 1 << 16);
    final outH = math.max(cornerDistance(tl, bl), cornerDistance(tr, br)).round().clamp(1, 1 << 16);

    final srcPts = cv.VecPoint.fromList([
      cv.Point(tl.dx.round(), tl.dy.round()),
      cv.Point(tr.dx.round(), tr.dy.round()),
      cv.Point(br.dx.round(), br.dy.round()),
      cv.Point(bl.dx.round(), bl.dy.round()),
    ]);
    final dstPts = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(outW, 0),
      cv.Point(outW, outH),
      cv.Point(0, outH),
    ]);

    final transform = track(cv.getPerspectiveTransform(srcPts, dstPts));
    final warped = track(cv.warpPerspective(src, transform, (outW, outH)));

    final (success, encoded) = cv.imencode('.jpg', warped);
    if (!success) {
      throw StateError('Failed to encode warped document image');
    }
    return encoded;
  } finally {
    for (final m in mats) {
      m.dispose();
    }
  }
}

/// Applies [filter] to an already-warped image. `original` is a no-op;
/// the other modes are wired up in a later phase.
Uint8List applyFilter(Uint8List warpedBytes, PageFilter filter) {
  switch (filter) {
    case PageFilter.original:
      return warpedBytes;
    case PageFilter.autoEnhance:
    case PageFilter.grayscale:
    case PageFilter.blackAndWhite:
      // TODO(phase-2): CLAHE auto-enhance, grayscale cvtColor, and
      // grayscale+adaptiveThreshold black-and-white.
      return warpedBytes;
  }
}
