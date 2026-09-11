import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/scanner_home_page.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Tesseract language data',
    ], await rootBundle.loadString('assets/tessdata/LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'Tesseract4Android and native OCR dependencies',
    ], await rootBundle.loadString('assets/tessdata/THIRD_PARTY_NOTICES.txt'));
  });
  runApp(const FOSScannerApp());
}

class FOSScannerApp extends StatelessWidget {
  const FOSScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
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
      home: const ScannerHomePage(),
    );
  }
}
