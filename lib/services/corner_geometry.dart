import 'dart:ui';

/// Orders 4 arbitrary points as top-left, top-right, bottom-right,
/// bottom-left, via the standard sum/diff trick: top-left has the smallest
/// (x+y), bottom-right the largest; top-right has the largest (x-y)
/// (large x, small y), bottom-left the smallest.
///
/// Pure geometry, no native/OpenCV dependency, so it's cheap to unit test
/// directly and safe to use from the web fallback too.
List<Offset> orderCorners(List<Offset> pts) {
  assert(pts.length == 4);
  final bySum = [...pts]..sort((a, b) => (a.dx + a.dy).compareTo(b.dx + b.dy));
  final byDiff = [...pts]..sort((a, b) => (a.dx - a.dy).compareTo(b.dx - b.dy));
  return [bySum.first, byDiff.last, bySum.last, byDiff.first];
}

double cornerDistance(Offset a, Offset b) => (a - b).distance;
