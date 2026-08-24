import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/corner_geometry.dart';

void main() {
  group('orderCorners', () {
    test('already-ordered points stay in the same order', () {
      const tl = Offset(10, 10);
      const tr = Offset(200, 12);
      const br = Offset(195, 300);
      const bl = Offset(8, 290);

      final result = orderCorners([tl, tr, br, bl]);

      expect(result, [tl, tr, br, bl]);
    });

    test('shuffled points get put back into tl,tr,br,bl order', () {
      const tl = Offset(10, 10);
      const tr = Offset(200, 12);
      const br = Offset(195, 300);
      const bl = Offset(8, 290);

      // Same 4 points, different input order (this is the exact bug caught
      // during the Phase 0 spike: tr/bl were being swapped).
      final result = orderCorners([br, tl, bl, tr]);

      expect(result, [tl, tr, br, bl]);
    });

    test('handles a keystoned (non-rectangular) quad', () {
      const tl = Offset(230, 160);
      const tr = Offset(1040, 90);
      const br = Offset(1080, 1430);
      const bl = Offset(170, 1500);

      final result = orderCorners([bl, br, tr, tl]);

      expect(result, [tl, tr, br, bl]);
    });

    test('does not duplicate corners when sums and differences tie', () {
      const top = Offset(50, 0);
      const right = Offset(100, 50);
      const bottom = Offset(50, 100);
      const left = Offset(0, 50);

      final result = orderCorners([left, bottom, top, right]);

      expect(result, [top, right, bottom, left]);
      expect(result.toSet(), hasLength(4));
    });

    test('anchors the top edge instead of the leftmost perspective point', () {
      const topLeft = Offset(400, 100);
      const topRight = Offset(600, 100);
      const bottomRight = Offset(900, 900);
      const bottomLeft = Offset(0, 300);

      final result = orderCorners([bottomLeft, bottomRight, topLeft, topRight]);

      expect(result, [topLeft, topRight, bottomRight, bottomLeft]);
    });

    test('rejects malformed input in release builds too', () {
      expect(
        () => orderCorners(const [Offset.zero, Offset(1, 1), Offset(2, 2)]),
        throwsArgumentError,
      );
    });
  });

  group('cornerDistance', () {
    test('computes straight-line distance between two points', () {
      expect(cornerDistance(const Offset(0, 0), const Offset(3, 4)), 5.0);
    });
  });

  test('warp budgets stay within the mobile memory envelope', () {
    expect(maxWarpPixels, 9000000);
    expect(maxWarpEdge, 4096);
    expect(maxPreviewWarpPixels, 2000000);
    expect(maxPreviewWarpEdge, 2048);
  });

  test('warp dimensions reject a degenerate crop', () {
    expect(
      () => calculateWarpSize(const [
        Offset.zero,
        Offset(100, 0),
        Offset(100, 0),
        Offset(0, 100),
      ]),
      throwsArgumentError,
    );
  });

  test('warp dimensions reject self-intersecting corners', () {
    expect(
      () => calculateWarpSize(const [
        Offset.zero,
        Offset(100, 100),
        Offset(100, 0),
        Offset(0, 80),
      ]),
      throwsArgumentError,
    );
  });

  test('warp dimensions reject source corners that collide when rounded', () {
    expect(
      () => calculateWarpSize(const [
        Offset(0.1, 0.1),
        Offset(0.4, 0.1),
        Offset(0.4, 10.1),
        Offset(0.1, 10.1),
      ]),
      throwsArgumentError,
    );
  });

  test('warp dimensions require output edges of at least two pixels', () {
    expect(
      () => calculateWarpSize(const [
        Offset.zero,
        Offset(1, 0),
        Offset(1, 10),
        Offset(0, 10),
      ]),
      throwsArgumentError,
    );
  });

  test('rejects crops that collapse below two pixels when bounded', () {
    expect(
      () => calculateWarpSize(const [
        Offset.zero,
        Offset(2, 0),
        Offset(2, 1000000),
        Offset(0, 1000000),
      ]),
      throwsArgumentError,
    );
  });

  test(
    'warp dimensions cap pathological image allocations while preserving aspect ratio',
    () {
      final (width, height) = calculateWarpSize(const [
        Offset.zero,
        Offset(100000, 0),
        Offset(100000, 50000),
        Offset(0, 50000),
      ]);

      expect(width * height, lessThanOrEqualTo(maxWarpPixels));
      expect(width, lessThanOrEqualTo(maxWarpEdge));
      expect(height, lessThanOrEqualTo(maxWarpEdge));
      expect(width / height, closeTo(2, 0.01));
    },
  );

  test('preview dimensions honor a smaller caller-provided budget', () {
    final (width, height) = calculateWarpSize(
      const [
        Offset.zero,
        Offset(10000, 0),
        Offset(10000, 5000),
        Offset(0, 5000),
      ],
      maxPixels: 2000000,
      maxEdge: 2048,
    );

    expect(width * height, lessThanOrEqualTo(2000000));
    expect(width, lessThanOrEqualTo(2048));
    expect(height, lessThanOrEqualTo(2048));
    expect(width / height, closeTo(2, 0.01));
  });

  test('extreme coordinates preserve aspect ratio when downscaled', () {
    final (width, height) = calculateWarpSize(const [
      Offset.zero,
      Offset(100000000, 0),
      Offset(100000000, 1000000),
      Offset(0, 1000000),
    ]);

    expect(width, lessThanOrEqualTo(maxWarpEdge));
    expect(height, greaterThanOrEqualTo(2));
    expect(width / height, closeTo(100, 1));
  });
}
