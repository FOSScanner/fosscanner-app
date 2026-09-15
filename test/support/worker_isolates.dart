import 'package:flutter_test/flutter_test.dart';

/// Pumps until [done] holds, letting real worker isolates deliver results.
///
/// The image-only PDF exporter hands page conversion and document assembly to
/// `compute`, and a fake-async widget test never delivers those results on its
/// own — only the real delay inside [WidgetTester.runAsync] does.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String? reason,
  int attempts = 1000,
}) async {
  for (var i = 0; i < attempts && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason ?? 'worker isolates never finished');
  await tester.pumpAndSettle();
}

/// [pumpUntil] a widget matching [finder] exists.
Future<void> pumpUntilFound(WidgetTester tester, Finder finder) => pumpUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  reason: 'no widget ever matched $finder',
);
