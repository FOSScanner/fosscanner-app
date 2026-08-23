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
    final kernel = track(cv.getStructuringElement(cv.MORPH_RECT, (3, 3)));
    final dilated = track(cv.dilate(edges, kernel));

    final (contours, _) = cv.findContours(dilated, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    try {
      final quad = _findDocumentQuad(contours, small.cols * small.rows);
      if (quad == null) return null;

      final invScale = 1.0 / scale;
      final scaledCorners = quad.map((p) => Offset(p.x * invScale, p.y * invScale)).toList();
      return orderCorners(scaledCorners);
    } finally {
      // IMPORTANT: dispose the VecVecPoint container itself, not its
      // individual contour elements — disposing elements one-by-one causes
      // a native double-free (confirmed via a standalone `dart run`
      // repro: crashes with SEGV_MAPERR in __libc_free during later
      // cleanup, only on non-trivial images).
      contours.dispose();
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
      // approx (unlike elements of `contours`) is its own real allocation,
      // not a view — safe and necessary to dispose directly.
      final points = approx.toList();
      approx.dispose();
      if (points.length == 4) return points;
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

/// Applies [filter] to an already-warped image. `original` is a no-op.
Uint8List applyFilter(Uint8List warpedBytes, PageFilter filter) {
  if (filter == PageFilter.original) return warpedBytes;

  final mats = <cv.Mat>[];
  cv.Mat track(cv.Mat m) {
    mats.add(m);
    return m;
  }

  try {
    final src = track(cv.imdecode(warpedBytes, cv.IMREAD_COLOR));
    final result = switch (filter) {
      PageFilter.original => src,
      PageFilter.grayscale => track(cv.cvtColor(src, cv.COLOR_BGR2GRAY)),
      PageFilter.blackAndWhite => track(_blackAndWhite(src, track)),
      PageFilter.autoEnhance => track(_autoEnhance(src, track)),
    };

    final (success, encoded) = cv.imencode('.jpg', result);
    if (!success) {
      throw StateError('Failed to encode filtered document image');
    }
    return encoded;
  } finally {
    for (final m in mats) {
      m.dispose();
    }
  }
}

/// Classic "scanned page" look: grayscale + adaptive threshold, so text
/// comes out crisp black-on-white regardless of uneven lighting in the
/// original photo. Block size scales with image size (must stay odd).
cv.Mat _blackAndWhite(cv.Mat src, cv.Mat Function(cv.Mat) track) {
  final gray = track(cv.cvtColor(src, cv.COLOR_BGR2GRAY));
  final blockSize = ((src.cols / 20).round() | 1).clamp(3, 9999);
  return cv.adaptiveThreshold(
    gray,
    255,
    cv.ADAPTIVE_THRESH_GAUSSIAN_C,
    cv.THRESH_BINARY,
    blockSize,
    10,
  );
}

/// Rotates [imageBytes] clockwise in 90-degree steps. [quarterTurns] is
/// normalized mod 4, so any integer (including negative, for counter-
/// clockwise) works; 0 is a no-op that returns [imageBytes] unchanged.
Uint8List rotateImage(Uint8List imageBytes, int quarterTurns) {
  final turns = quarterTurns % 4;
  final normalized = turns < 0 ? turns + 4 : turns;
  if (normalized == 0) return imageBytes;

  final rotateCode = switch (normalized) {
    1 => cv.ROTATE_90_CLOCKWISE,
    2 => cv.ROTATE_180,
    _ => cv.ROTATE_90_COUNTERCLOCKWISE,
  };

  final mats = <cv.Mat>[];
  cv.Mat track(cv.Mat m) {
    mats.add(m);
    return m;
  }

  try {
    final src = track(cv.imdecode(imageBytes, cv.IMREAD_COLOR));
    final rotated = track(cv.rotate(src, rotateCode));
    final (success, encoded) = cv.imencode('.jpg', rotated);
    if (!success) {
      throw StateError('Failed to encode rotated document image');
    }
    return encoded;
  } finally {
    for (final m in mats) {
      m.dispose();
    }
  }
}

/// Adjusts brightness/contrast on top of an already-warped/filtered image:
/// `output = input * contrast + brightness` per pixel, saturated to the
/// valid 0-255 range. `contrast == 1.0 && brightness == 0.0` is a no-op
/// that returns [imageBytes] unchanged.
Uint8List adjustBrightnessContrast(
  Uint8List imageBytes, {
  required double brightness,
  required double contrast,
}) {
  if (brightness == 0.0 && contrast == 1.0) return imageBytes;

  final mats = <cv.Mat>[];
  cv.Mat track(cv.Mat m) {
    mats.add(m);
    return m;
  }

  try {
    final src = track(cv.imdecode(imageBytes, cv.IMREAD_COLOR));
    final adjusted = track(src.convertTo(src.type, alpha: contrast, beta: brightness));
    final (success, encoded) = cv.imencode('.jpg', adjusted);
    if (!success) {
      throw StateError('Failed to encode brightness/contrast-adjusted image');
    }
    return encoded;
  } finally {
    for (final m in mats) {
      m.dispose();
    }
  }
}

/// "Magic color"-style enhance: CLAHE (local contrast boost) on the L
/// channel of Lab color space, leaving color (a/b channels) untouched so
/// this doesn't shift color balance, just makes text/background pop more.
cv.Mat _autoEnhance(cv.Mat src, cv.Mat Function(cv.Mat) track) {
  final lab = track(cv.cvtColor(src, cv.COLOR_BGR2Lab));
  final channels = cv.split(lab);
  for (final c in channels) {
    track(c);
  }
  final clahe = cv.createCLAHE(clipLimit: 2.0, tileGridSize: (8, 8));
  final enhancedL = track(clahe.apply(channels[0]));
  clahe.dispose();
  final merged = track(cv.merge(cv.VecMat.fromList([enhancedL, channels[1], channels[2]])));
  return cv.cvtColor(merged, cv.COLOR_Lab2BGR);
}
