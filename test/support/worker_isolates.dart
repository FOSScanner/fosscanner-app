import 'package:flutter_test/flutter_test.dart';

/// Pumps until [done] holds, letting real worker isolates deliver results.
///
/// The image-only PDF exporter hands page conversion and document assembly to
/// `compute`, and a fake-async widget test never delivers those results on its
/// own — only the real delay inside [WidgetTester.runAsync] does.
///
/// Pass `settle: false` when [done] holds while an export is still running: its
/// progress spinner keeps scheduling frames, which `pumpAndSettle` waits for
/// until it times out.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String? reason,
  bool settle = true,
  int attempts = 1000,
}) async {
  for (var i = 0; i < attempts && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    // The first pump hands a delivered worker result to the fake-async zone,
    // the second draws the frame its setState scheduled. Without the second
    // one a caller could miss an intermediate state entirely, because the
    // next real delay would already have started the following step.
    await tester.pump();
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason ?? 'worker isolates never finished');
  if (settle) await tester.pumpAndSettle();
}

/// [pumpUntil] a widget matching [finder] exists.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) => pumpUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  reason: 'no widget ever matched $finder',
  settle: settle,
);
