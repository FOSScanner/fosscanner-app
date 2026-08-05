import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

void main() {
  testWidgets('shows a loading state while the photo is being decoded', (tester) async {
    // Genuinely-invalid bytes are intentional: this only exercises the
    // widget's build before/without the async _initialize() chain
    // resolving successfully. Real image decoding via
    // ui.instantiateImageCodec is known to hang forever under
    // flutter_test's fake-time test binding even though it works fine in
    // the real app (verified separately, see CLAUDE.md) — full pipeline
    // correctness is covered by the Phase 0 spike script and on-device
    // testing instead.
    final bytes = Uint8List.fromList(const [0, 1, 2, 3]);

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(originalBytes: bytes),
      ),
    );

    expect(find.text('Adjust corners'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows an error state (not an infinite spinner) when decoding fails', (tester) async {
    final bytes = Uint8List.fromList(const [0, 1, 2, 3]);

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(originalBytes: bytes),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not read this photo'), findsOneWidget);
    expect(find.text('Go back'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
