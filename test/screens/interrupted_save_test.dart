import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/pdf_document_saver.dart';

void main() {
  const channel = MethodChannel('com.fosscanner.app/ocr');
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'asks MainActivity once and reports whether a save was removed',
    () async {
      final calls = <String>[];
      Object? reply = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (reply case final Exception error) throw error;
        return reply;
      });
      expect(await PlatformPdfDocumentSaver.removeInterruptedSave(), isTrue);
      reply = false;
      expect(await PlatformPdfDocumentSaver.removeInterruptedSave(), isFalse);
      reply = null;
      expect(await PlatformPdfDocumentSaver.removeInterruptedSave(), isFalse);
      reply = PlatformException(code: 'boom');
      expect(await PlatformPdfDocumentSaver.removeInterruptedSave(), isFalse);
      expect(calls, everyElement('removeInterruptedSave'));
      expect(
        File(
          'android/app/src/main/kotlin/com/fosscanner/app/MainActivity.kt',
        ).readAsStringSync(),
        contains('"removeInterruptedSave" -> handleRemoveInterruptedSave'),
      );
    },
  );

  test('missing native handler is not an error', () async {
    expect(await PlatformPdfDocumentSaver.removeInterruptedSave(), isFalse);
  });

  Future<void> pumpHome(
    WidgetTester tester,
    Future<bool> Function()? remover,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          searchablePdfEnabled: false,
          interruptedSaveRemover: remover,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tells the user once when an empty save was removed', (
    tester,
  ) async {
    var calls = 0;
    await pumpHome(tester, () async {
      calls++;
      return true;
    });
    expect(calls, 1);
    expect(find.text('An interrupted save was removed.'), findsOneWidget);
  });

  for (final outcome in ['nothing to remove', 'failure']) {
    testWidgets('says nothing when there was $outcome', (tester) async {
      await pumpHome(
        tester,
        () => outcome == 'failure'
            ? Future<bool>.error(StateError('injected'))
            : Future.value(false),
      );
      expect(find.text('An interrupted save was removed.'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no remover, no message', (tester) async {
    await pumpHome(tester, null);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a removal finishing after the screen closed is ignored', (
    tester,
  ) async {
    final pending = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          searchablePdfEnabled: false,
          interruptedSaveRemover: () => pending.future,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
