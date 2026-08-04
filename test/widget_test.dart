import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/main.dart';

void main() {
  testWidgets('shows the empty state and capture button on launch', (WidgetTester tester) async {
    await tester.pumpWidget(const FOSScannerApp());

    expect(find.text('FOSScanner'), findsOneWidget);
    expect(find.text('Ready to Scan'), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt), findsWidgets);

    // No captured pages yet, so there's nothing to clear or export.
    expect(find.byIcon(Icons.clear_all), findsNothing);
    expect(find.text('Save as PDF'), findsNothing);
  });
}
