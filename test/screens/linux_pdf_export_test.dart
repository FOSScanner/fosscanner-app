import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

class _SaveDialog extends FileSelectorPlatform {
  String? destination;
  int calls = 0;
  SaveDialogOptions? lastOptions;
  List<XTypeGroup>? lastTypes;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    calls++;
    lastOptions = options;
    lastTypes = acceptedTypeGroups;
    return destination == null ? null : FileSaveLocation(destination!);
  }
}

class _SharePlatform implements SharePlatform {
  int calls = 0;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    throw UnimplementedError('Sharing files not supported on Linux');
  }
}

Future<void> _export(WidgetTester tester) async {
  await tester.runAsync(() => tester.tap(find.text('Save as PDF (1 pages)')));
  for (var i = 0; i < 100; i++) {
    await tester.pump();
    if (find.text('Generating PDF...').evaluate().isEmpty) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
  expect(find.text('Generating PDF...'), findsNothing);
}

void main() {
  late FileSelectorPlatform originalSelector;
  late _SaveDialog selector;
  late _SharePlatform share;
  late Directory temporary;

  setUp(() {
    originalSelector = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = selector = _SaveDialog();
    share = _SharePlatform();
    temporary = Directory.systemTemp.createTempSync('linux-pdf-export-');
  });

  tearDown(() {
    FileSelectorPlatform.instance = originalSelector;
    temporary.deleteSync(recursive: true);
  });

  Future<void> showPage(WidgetTester tester) async {
    final bytes = File('assets/icon/icon.png').readAsBytesSync();
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: [
            ScannedPage(
              originalBytes: bytes,
              corners: const [],
              processedBytes: bytes,
            ),
          ],
          sharePlus: SharePlus.custom(share),
          searchablePdfEnabled: false,
        ),
      ),
    );
  }

  testWidgets(
    'Linux saves generated PDF bytes to the selected file',
    (tester) async {
      final output = File('${temporary.path}/selected-document.pdf');
      selector.destination = output.path;
      await showPage(tester);
      await _export(tester);

      expect(selector.calls, 1);
      expect(share.calls, 0);
      expect(
        selector.lastOptions!.suggestedName,
        matches(r'^FOSScanner_\d+\.pdf$'),
      );
      expect(selector.lastTypes!.single.extensions, ['pdf']);
      expect(output.existsSync(), isTrue);
      final contents = String.fromCharCodes(output.readAsBytesSync());
      expect(contents, startsWith('%PDF-'));
      expect(RegExp(r'/Subtype\s*/Image').hasMatch(contents), isTrue);
      expect(contents.trimRight(), endsWith('%%EOF'));
      expect(find.text('Keep this draft?'), findsOneWidget);
      await tester.tap(find.text('Keep draft'));
      await tester.pumpAndSettle();
      expect(find.text('Save as PDF (1 pages)'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'cancelled Linux save keeps pages without reporting an export',
    (tester) async {
      await showPage(tester);
      await _export(tester);

      expect(selector.calls, 1);
      expect(share.calls, 0);
      expect(temporary.listSync(), isEmpty);
      expect(find.text('Keep this draft?'), findsNothing);
      expect(find.text('Save as PDF (1 pages)'), findsOneWidget);
      expect(find.textContaining('Could not create a PDF'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'failed Linux file write reports failure and retains the draft',
    (tester) async {
      selector.destination = '${temporary.path}/missing/document.pdf';
      await showPage(tester);
      await _export(tester);

      expect(selector.calls, 1);
      expect(share.calls, 0);
      expect(find.textContaining('Could not create a PDF'), findsOneWidget);
      expect(find.text('Keep this draft?'), findsNothing);
      expect(find.text('Save as PDF (1 pages)'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
