import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/scanner_home_page.dart';
import 'services/draft_store.dart';
import 'widgets/draft_session_gate.dart';

/// Register native notices not collected from Dart package LICENSE files.
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (name, asset) in [
      ('ZXing and Zint native barcode libraries', 'BARCODE_NOTICES.txt'),
      ('OpenCV and native image dependencies', 'OPENCV_NOTICES.txt'),
      ('KleidiCV', 'KLEIDICV_NOTICES.txt'),
      ('AndroidX CameraX and libyuv', 'CAMERAX_NOTICES.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/licenses/$asset'));
    }
    yield LicenseEntryWithLineBreaks([
      'Tesseract language data',
    ], await rootBundle.loadString('assets/tessdata/LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'Tesseract4Android and native OCR dependencies',
    ], await rootBundle.loadString('assets/tessdata/THIRD_PARTY_NOTICES.txt'));
  });
}

void main() {
  registerBundledLicenses();
  runApp(FOSScannerApp(draftStore: createDraftStore()));
}

class FOSScannerApp extends StatelessWidget {
  const FOSScannerApp({super.key, this.draftStore});

  final DraftStore? draftStore;

  @override
  Widget build(BuildContext context) {
    final store = draftStore ?? const NoOpDraftStore();
    final scanner = ScannerHomePage(draftStore: store);
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
