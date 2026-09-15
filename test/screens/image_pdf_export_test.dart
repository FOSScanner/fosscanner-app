import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../support/worker_isolates.dart';

class _Share implements SharePlatform {
  Uint8List? output;
  var calls = 0;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    output = await params.files!.single.readAsBytes();
    return const ShareResult('', ShareResultStatus.dismissed);
  }
}

void main() {
  late Uint8List input;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    input = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  Future<_Share> pumpHome(WidgetTester tester, int pageCount) async {
    final platform = _Share();
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: [
            for (var i = 0; i < pageCount; i++)
              ScannedPage(
                originalBytes: input,
                processedBytes: input,
                corners: const [],
              ),
          ],
          searchablePdfEnabled: false,
          sharePlus: SharePlus.custom(platform),
        ),
      ),
    );
    return platform;
  }

  testWidgets('PNG pages use compressed image data inside the exported PDF', (
    tester,
  ) async {
    final platform = await pumpHome(tester, 1);
    await tester.tap(find.text('Save as PDF (1 pages)'));
    await pumpUntil(tester, () => platform.output != null);
    expect(latin1.decode(platform.output!), contains('/DCTDecode'));
  });

  testWidgets('image-only export reports progress while a worker converts', (
    tester,
  ) async {
    final platform = await pumpHome(tester, 2);
    await tester.tap(find.text('Save as PDF (2 pages)'));
    await tester.pump();

    // Conversion is handed to a worker, so the screen keeps rendering a
    // percentage and an enabled Cancel while the export is in flight.
    expect(find.textContaining(RegExp(r'Generating PDF \d+%')), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
    );

    await pumpUntil(tester, () => platform.output != null);
    expect(find.text('Save as PDF (2 pages)'), findsOneWidget);
  });

  testWidgets('cancelling an image-only export stops before sharing', (
    tester,
  ) async {
    final platform = await pumpHome(tester, 2);
    await tester.tap(find.text('Save as PDF (2 pages)'));
    await tester.pump();

    // Cancelling mid-export: worker results only arrive once the real delays
    // inside pumpUntil let them through, so this lands before assembly.
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    expect(find.text('Cancelling PDF...'), findsOneWidget);

    await pumpUntilFound(tester, find.text('PDF generation cancelled.'));
    expect(platform.calls, 0);
    expect(find.text('Keep this draft?'), findsNothing);
    expect(find.text('Save as PDF (2 pages)'), findsOneWidget);
  });
}
