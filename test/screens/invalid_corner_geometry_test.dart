import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

Future<Uint8List> _iconBytes() async {
  final data = await rootBundle.load('assets/icon/icon.png');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<void> _pumpUntilReady(WidgetTester tester) async {
  for (var i = 0; i < 20 && find.text('Next').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('an invalid crop cannot enter the preview step', (tester) async {
    final bytes = await _iconBytes();

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: const [
            Offset(80, 80),
            Offset(95, 5),
            Offset(95, 95),
            Offset(5, 95),
          ],
        ),
      ),
    );
    await _pumpUntilReady(tester);

    expect(find.text('Next'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pump();

    expect(find.text('Edit page'), findsOneWidget);
    expect(find.text('Preview'), findsNothing);
    expect(find.textContaining('Could not preview this crop'), findsOneWidget);
  });

  testWidgets('malformed initial corners fall back without crashing', (
    tester,
  ) async {
    final bytes = await _iconBytes();

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: const [Offset.zero, Offset(100, 0), Offset(100, 100)],
        ),
      ),
    );
    await _pumpUntilReady(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Next'), findsOneWidget);
  });
}
