import 'dart:math' as math;

/// Contrast multipliers the Adjust sheet offers. Saved pages keep the
/// multiplier itself; only the slider position is mapped.
const minContrast = 0.5;
const maxContrast = 2.0;

/// Slider position for [contrast] on a log2 scale, so 0.5× and 2.0× sit at
/// the ends (-1 and 1) and neutral 1.0× sits exactly in the middle (0).
double contrastToSliderPosition(double contrast) {
  if (!contrast.isFinite || contrast <= 0) return 0;
  final clamped = contrast.clamp(minContrast, maxContrast);
  return math.log(clamped) / math.ln2;
}

/// The contrast multiplier for a slider [position]; the inverse of
/// [contrastToSliderPosition].
double sliderPositionToContrast(double position) {
  if (!position.isFinite) return 1;
  if (position == 0) return 1;
  final contrast = math.pow(2, position.clamp(-1.0, 1.0)).toDouble();
  return contrast.clamp(minContrast, maxContrast);
}
