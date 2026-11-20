import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One viewport and text scale in the layout-stability matrix.
class LayoutCase {
  const LayoutCase(this.size, this.textScale);

  final Size size;
  final double textScale;

  @override
  String toString() =>
      '${size.width.toInt()}x${size.height.toInt()} @${textScale}x';
}

/// Small phone, regular phone, short landscape and portrait tablet at the
/// default, a common enlarged, and the maximum supported text scale.
const layoutSizes = [
  Size(320, 568),
  Size(390, 844),
  Size(640, 300),
  Size(800, 1280),
];
const layoutTextScales = [1.0, 1.3, 2.0];

final layoutMatrix = [
  for (final size in layoutSizes)
    for (final scale in layoutTextScales) LayoutCase(size, scale),
];

/// The largest display size and font QA uses: a 1080 × 2400 phone at
/// density 560 with 2.0× font, tested as 412 × 915 logical pixels, and the
/// same screen at its physical density (308 × 686).
const highDensityLargeTextCases = [
  LayoutCase(Size(412, 915), 2.0),
  LayoutCase(Size(308, 686), 2.0),
];

/// The phone sizes of [layoutSizes] at the maximum text scale, plus
/// [highDensityLargeTextCases].
const largeDisplayCases = [
  LayoutCase(Size(320, 568), 2.0),
  LayoutCase(Size(390, 844), 2.0),
  ...highDensityLargeTextCases,
];

/// Applies [layoutCase]'s physical size; the text scale must be applied by
/// wrapping the app with [withTextScale].
void applyLayoutCase(WidgetTester tester, LayoutCase layoutCase) {
  tester.view.physicalSize = layoutCase.size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A `MaterialApp.builder` that forces a linear text scale.
TransitionBuilder withTextScale(double textScale) =>
    (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    );

/// Registers one test per [layoutMatrix] entry (or [cases]).
void testLayoutMatrix(
  String description,
  Future<void> Function(WidgetTester tester, LayoutCase layoutCase) body, {
  Iterable<LayoutCase>? cases,
  TargetPlatformVariant? variant,
}) {
  for (final layoutCase in cases ?? layoutMatrix) {
    testWidgets('$description [$layoutCase]', (tester) async {
      applyLayoutCase(tester, layoutCase);
      await body(tester, layoutCase);
    }, variant: variant ?? const DefaultTestVariant());
  }
}

/// Captures the global rect of every finder in [anchors]. Each finder must
/// match exactly one widget.
Map<String, Rect> captureRects(
  WidgetTester tester,
  Map<String, Finder> anchors,
) => {
  for (final entry in anchors.entries) entry.key: tester.getRect(entry.value),
};

/// Asserts that every anchor keeps its rect (within [tolerance] logical
/// pixels) across [transition]. Use it to prove that state changes such as
/// progress, errors or optional actions do not move content the user is
/// looking at or touching.
Future<void> expectStableRects(
  WidgetTester tester,
  Map<String, Finder> anchors,
  Future<void> Function() transition, {
  double tolerance = 0.5,
  String? reason,
}) async {
  final before = captureRects(tester, anchors);
  await transition();
  final after = captureRects(tester, anchors);
  for (final name in anchors.keys) {
    final a = before[name]!;
    final b = after[name]!;
    final moved =
        (a.left - b.left).abs() > tolerance ||
        (a.top - b.top).abs() > tolerance ||
        (a.width - b.width).abs() > tolerance ||
        (a.height - b.height).abs() > tolerance;
    expect(
      moved,
      isFalse,
      reason: '${reason == null ? '' : '$reason: '}"$name" moved from $a to $b',
    );
  }
}
