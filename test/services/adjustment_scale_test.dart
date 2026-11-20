import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/adjustment_scale.dart';

void main() {
  test('neutral contrast sits exactly in the middle of the track', () {
    expect(contrastToSliderPosition(1), 0);
    expect(sliderPositionToContrast(0), 1);
  });

  test('the ends of the track are the contrast limits', () {
    expect(contrastToSliderPosition(minContrast), closeTo(-1, 1e-12));
    expect(contrastToSliderPosition(maxContrast), closeTo(1, 1e-12));
    expect(sliderPositionToContrast(-1), closeTo(minContrast, 1e-12));
    expect(sliderPositionToContrast(1), closeTo(maxContrast, 1e-12));
  });

  test('halving and doubling are symmetric around neutral', () {
    expect(
      contrastToSliderPosition(1 / 1.5),
      closeTo(-contrastToSliderPosition(1.5), 1e-12),
    );
  });

  test('saved values round-trip unchanged', () {
    for (final contrast in [0.5, 0.73, 1.0, 1.25, 1.5, 2.0]) {
      expect(
        sliderPositionToContrast(contrastToSliderPosition(contrast)),
        closeTo(contrast, 1e-9),
        reason: '$contrast',
      );
    }
  });

  test('out-of-range and invalid values stay on the track', () {
    expect(contrastToSliderPosition(5), closeTo(1, 1e-12));
    expect(contrastToSliderPosition(0.1), closeTo(-1, 1e-12));
    expect(contrastToSliderPosition(0), 0);
    expect(contrastToSliderPosition(double.nan), 0);
    expect(sliderPositionToContrast(3), maxContrast);
    expect(sliderPositionToContrast(double.infinity), 1);
  });
}
