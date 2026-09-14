import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

class _Share implements SharePlatform {
  Uint8List? output;

  @override
  Future<ShareResult> share(ShareParams params) async {
    output = await params.files!.single.readAsBytes();
    return const ShareResult('', ShareResultStatus.dismissed);
  }
}

void main() {
  testWidgets('PNG pages use compressed image data inside the exported PDF', (
    tester,
  ) async {
    final data = await rootBundle.load('assets/icon/icon.png');
    final input = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final platform = _Share();
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: [
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
    await tester.tap(find.text('Save as PDF (1 pages)'));
    await tester.pumpAndSettle();
    expect(platform.output, isNotNull);
    expect(latin1.decode(platform.output!), contains('/DCTDecode'));
  });
}
