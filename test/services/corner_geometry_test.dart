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
  });

  group('cornerDistance', () {
    test('computes straight-line distance between two points', () {
      expect(cornerDistance(const Offset(0, 0), const Offset(3, 4)), 5.0);
    });
  });
}
