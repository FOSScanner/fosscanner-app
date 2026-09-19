import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/screens/barcode_scan_screen.dart';

void main() {
  late ValueChanged<BarcodeScanResult> emitScan;

  Widget buildScreen({
    Future<void> Function(String)? clipboardWriter,
    Future<bool> Function(Uri)? uriLauncher,
  }) => MaterialApp(
    home: BarcodeScanScreen(
      scanViewBuilder: (context, onScan) {
        emitScan = onScan;
        return const SizedBox.expand(child: ColoredBox(color: Colors.black));
      },
      clipboardWriter: clipboardWriter ?? (_) async {},
      uriLauncher: uriLauncher ?? (_) async => true,
    ),
  );

  testWidgets('latches the first valid result until it is dismissed', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(buildScreen());

    emitScan(const BarcodeScanResult(isValid: false, text: 'invalid'));
    emitScan(const BarcodeScanResult(isValid: true, text: ''));
    emitScan(const BarcodeScanResult(isValid: true, text: 'first'));
    await tester.pump();
    emitScan(const BarcodeScanResult(isValid: true, text: 'second'));
    await tester.pump();

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
    final resultNode = tester.getSemantics(
      find.bySemanticsLabel('Scanned code result: first'),
    );
    expect(resultNode.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    expect(find.bySemanticsLabel('Copy scanned result'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss and keep scanning'));
    await tester.pump();
    emitScan(const BarcodeScanResult(isValid: true, text: 'second'));
    await tester.pump();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('clipboard failures show stable transient feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildScreen(
        clipboardWriter: (_) async => throw StateError('secret clipboard'),
      ),
    );
    emitScan(const BarcodeScanResult(isValid: true, text: 'copy me'));
    await tester.pump();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not copy to clipboard.'), findsOneWidget);
    expect(find.textContaining('secret clipboard'), findsNothing);
  });

  testWidgets('offers and launches an HTTP URI', (tester) async {
    Uri? launched;
    await tester.pumpWidget(
      buildScreen(
        uriLauncher: (uri) async {
          launched = uri;
          return true;
        },
      ),
    );
    emitScan(
      const BarcodeScanResult(isValid: true, text: 'http://example.com/a'),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pump();

    expect(launched, Uri.parse('http://example.com/a'));
  });

  testWidgets('does not offer Open for a non-HTTP URI', (tester) async {
    await tester.pumpWidget(buildScreen());
    emitScan(
      const BarcodeScanResult(isValid: true, text: 'mailto:test@example.com'),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Open scanned link'), findsNothing);
  });

  testWidgets('does not offer Open for a hostless HTTPS URI', (tester) async {
    await tester.pumpWidget(buildScreen());
    emitScan(const BarcodeScanResult(isValid: true, text: 'https:foo'));
    await tester.pump();

    expect(find.bySemanticsLabel('Open scanned link'), findsNothing);
  });

  for (final launchFailure in <String, Future<bool> Function(Uri)>{
    'false': (_) async => false,
    'throw': (_) async => throw StateError('private launcher details'),
  }.entries) {
    testWidgets('shows stable feedback when URL launch ${launchFailure.key}s', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen(uriLauncher: launchFailure.value));
      emitScan(
        const BarcodeScanResult(isValid: true, text: 'https://example.com'),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not open the link.'), findsOneWidget);
      expect(find.textContaining('private launcher details'), findsNothing);
    });
  }
}
