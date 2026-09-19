import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/widgets/transient_message.dart';

void main() {
  testWidgets('a new transient message replaces the current SnackBar', (
    tester,
  ) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    showTransientMessage(pageContext, 'First message');
    await tester.pumpAndSettle();
    expect(find.text('First message'), findsOneWidget);

    showTransientMessage(pageContext, 'Second message');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('First message'), findsNothing);
    expect(find.text('Second message'), findsOneWidget);
  });

  testWidgets('a deferred stale message cannot replace a newer message', (
    tester,
  ) async {
    var scheduleMessages = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              if (scheduleMessages) {
                scheduleMessages = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  showTransientMessage(context, 'New message');
                });
                showTransientMessage(context, 'Stale message');
              }
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New message'), findsOneWidget);
    expect(find.text('Stale message'), findsNothing);
  });
}
