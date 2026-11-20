import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/scanner_home_page.dart';
import 'services/app_preferences.dart';
import 'services/draft_store.dart';
import 'services/pdf_export_files.dart';
import 'services/pdf_page_importer.dart';
import 'services/shared_image_inbox.dart';
import 'widgets/draft_session_gate.dart';

void main() {
  registerBundledLicenses();
  // Remove exports a killed process could not clean up. Nothing can be
  // exporting yet, so this cannot race a live export.
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(sweepStalePdfExports());
  runApp(
    FOSScannerApp(
      draftStore: createDraftStore(),
      preferencesStore: FileAppPreferencesStore(),
    ),
  );
}

/// Adds the bundled OCR components to Flutter's license registry so they are
/// listed on the license page opened from About.
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Tesseract language data',
    ], await rootBundle.loadString('assets/tessdata/LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'Tesseract4Android and native OCR dependencies',
    ], await rootBundle.loadString('assets/tessdata/THIRD_PARTY_NOTICES.txt'));
  });
}

class FOSScannerApp extends StatelessWidget {
  const FOSScannerApp({super.key, this.draftStore, this.preferencesStore});

  final DraftStore? draftStore;
  final AppPreferencesStore? preferencesStore;

  @override
  Widget build(BuildContext context) {
    final store = draftStore ?? const NoOpDraftStore();
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final scanner = ScannerHomePage(
      draftStore: store,
      // iOS would need a Share Extension target; only Android accepts shares.
      sharedImageInbox: isAndroid
          ? MethodChannelSharedImageInbox.instance
          : null,
      // iOS would need a PDFKit renderer; only Android imports PDFs.
      pdfPageImporter: isAndroid ? MethodChannelPdfPageImporter.instance : null,
      preferencesStore: preferencesStore,
    );
    return MaterialApp(
      title: 'FOSScanner',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: store is DraftSessionStore
          ? DraftSessionGate(
              key: ObjectKey(store),
              session: store as DraftSessionStore,
              child: scanner,
            )
          : scanner,
    );
  }
}
