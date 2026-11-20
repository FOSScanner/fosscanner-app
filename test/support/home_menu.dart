import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the home overflow menu.
Future<void> openHomeMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
}

/// Chooses "Clear all pages" from the overflow menu, which opens the
/// confirmation dialog.
Future<void> tapClearAllPages(WidgetTester tester) async {
  await openHomeMenu(tester);
  await tester.tap(find.text('Clear all pages'));
  await tester.pumpAndSettle();
}

/// Whether the overflow menu currently offers "Clear all pages". Opens and
/// closes the menu.
Future<bool> isClearAllPagesEnabled(WidgetTester tester) async {
  await openHomeMenu(tester);
  final enabled = tester
      .widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('Clear all pages'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      )
      .enabled;
  await tester.tapAt(Offset.zero);
  await tester.pumpAndSettle();
  return enabled;
}
