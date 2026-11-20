import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/scanner_home_page.dart';
import 'services/draft_store.dart';
import 'services/shared_image_inbox.dart';
import 'widgets/draft_session_gate.dart';

void main() {
  registerBundledLicenses();
  runApp(FOSScannerApp(draftStore: createDraftStore()));
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
  const FOSScannerApp({super.key, this.draftStore});

  final DraftStore? draftStore;

  @override
  Widget build(BuildContext context) {
    final store = draftStore ?? const NoOpDraftStore();
    final scanner = ScannerHomePage(
      draftStore: store,
      // iOS would need a Share Extension target; only Android accepts shares.
      sharedImageInbox:
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? MethodChannelSharedImageInbox.instance
          : null,
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
