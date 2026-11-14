import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/screens/barcode_scan_screen.dart';

void main() {
  late ValueChanged<BarcodeScanResult> emit;
  String? copied;
  Uri? opened;

  setUp(() {
    copied = null;
    opened = null;
  });

  Future<void> showResult(
    WidgetTester tester,
    String text, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: BarcodeScanScreen(
          scanViewBuilder: (context, onScan) {
            emit = onScan;
            return IconButton(
              onPressed: () {},
              tooltip: 'Camera control',
              icon: const Icon(Icons.flash_on),
            );
          },
          clipboardWriter: (text) async {
            copied = text;
          },
          uriLauncher: (uri) async {
            opened = uri;
            return true;
          },
        ),
      ),
    );
    emit(BarcodeScanResult(isValid: true, text: text));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'long URL remains complete and selectable with the actual host separate',
    (tester) async {
      final url =
          'https://trusted.example@destination.example/${'long-segment/' * 120}?end=visible#fragment';
      await showResult(tester, url);
      final result = tester.widget<SelectableText>(
        find.byKey(const Key('barcode_result_text')),
      );
      expect(result.data, url);
      expect(result.maxLines, isNull);
      expect(result.enableInteractiveSelection, isTrue);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('barcode_destination_host')),
            )
            .data,
        'destination.example',
      );
      expect(opened, isNull);
      expect(copied, isNull);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('barcode_result_scroll_view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
      await tester.pump();
      expect(copied, url);
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pump();
      expect(opened, Uri.parse(url));
    },
  );

  testWidgets(
    'long arbitrary text is complete, scrollable, and copied exactly',
    (tester) async {
      final text =
          '${'Inventory line\n' * 150}Last line: <not HTML> & \'quoted\'';
      await showResult(tester, text);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('barcode_result_text')),
            )
            .data,
        text,
      );
      expect(find.byKey(const Key('barcode_destination_host')), findsNothing);
      expect(find.bySemanticsLabel('Open scanned link'), findsNothing);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('barcode_result_scroll_view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
      await tester.pump();
      expect(copied, text);
      expect(opened, isNull);
    },
  );

  for (final text in [
    'javascript:alert(1)',
    'data:text/html,<script>alert(1)</script>',
    'file:///private/document',
    'tel:+1234567',
    '//example.com/path',
    'https:///path',
    'https://',
    'https://[invalid',
    'https://[::1',
  ]) {
    testWidgets('does not offer external opening for $text', (tester) async {
      await showResult(tester, text);
      expect(find.bySemanticsLabel('Open scanned link'), findsNothing);
      expect(find.byKey(const Key('barcode_destination_host')), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
      await tester.pump();
      expect(copied, text);
      expect(opened, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'review hides camera controls and Scan another resumes without opening a link',
    (tester) async {
      await showResult(tester, 'https://example.com');
      expect(find.byTooltip('Camera control'), findsNothing);
      final retainedCamera = find
          .byTooltip('Camera control', skipOffstage: false)
          .evaluate()
          .single;
      expect(find.byTooltip('Scan another'), findsOneWidget);
      emit(const BarcodeScanResult(isValid: true, text: 'ignored'));
      await tester.pump();
      expect(find.text('ignored'), findsNothing);
      await tester.tap(find.byTooltip('Scan another'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Camera control'), findsOneWidget);
      expect(
        find.byTooltip('Camera control').evaluate().single,
        same(retainedCamera),
      );
      expect(find.byKey(const Key('barcode_result_text')), findsNothing);
      emit(const BarcodeScanResult(isValid: true, text: 'next result'));
      await tester.pumpAndSettle();
      expect(find.text('next result'), findsOneWidget);
      expect(opened, isNull);
    },
  );

  testWidgets(
    'screen readers encounter the host and full result before body actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await showResult(tester, 'https://destination.example/path?full=value');
        final root = tester.getSemantics(find.byType(Scaffold));
        final spoken = <String>[];
        void collect(SemanticsNode node) {
          final data = node.getSemanticsData();
          spoken.add('${data.label} ${data.value}');
          for (final child in node.debugListChildrenInOrder(
            DebugSemanticsDumpOrder.traversalOrder,
          )) {
            collect(child);
          }
        }

        collect(root);
        final host = spoken.indexWhere(
          (s) => s.contains('destination.example') && !s.contains('/path'),
        );
        final full = spoken.indexWhere(
          (s) => s.contains('https://destination.example/path?full=value'),
        );
        final copy = spoken.indexWhere(
          (s) => s.contains('Copy scanned result'),
        );
        final open = spoken.indexWhere((s) => s.contains('Open scanned link'));
        expect(host, greaterThanOrEqualTo(0));
        expect(full, greaterThan(host));
        expect(copy, greaterThan(full));
        expect(open, greaterThan(full));
        expect(spoken.any((s) => s.contains('Camera control')), isFalse);
        expect(
          tester
              .getSemantics(find.byKey(const Key('barcode_result_semantics')))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    for (final text in [
      'https://example.com/${'segment/' * 100}',
      'Scanned text\n' * 100,
    ]) {
      testWidgets(
        'complete review and actions fit $size with 200% text (${text.startsWith('https') ? 'URL' : 'text'})',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await showResult(tester, text, textScale: 2);
          expect(tester.takeException(), isNull);
          expect(
            find.widgetWithText(OutlinedButton, 'Copy').hitTestable(),
            findsOneWidget,
          );
          if (text.startsWith('https')) {
            expect(
              find.widgetWithText(FilledButton, 'Open').hitTestable(),
              findsOneWidget,
            );
          }
          expect(find.byTooltip('Scan another').hitTestable(), findsOneWidget);
          await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
          await tester.pumpAndSettle();
          expect(copied, text);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
