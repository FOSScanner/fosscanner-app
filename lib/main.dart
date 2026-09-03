import 'package:flutter/material.dart';

import 'screens/scanner_home_page.dart';
import 'services/draft_store.dart';

void main() {
  runApp(FOSScannerApp(draftStore: createDraftStore()));
}

class FOSScannerApp extends StatelessWidget {
  const FOSScannerApp({super.key, this.draftStore});

  final DraftStore? draftStore;

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
      home: ScannerHomePage(draftStore: draftStore ?? const NoOpDraftStore()),
    );
  }
}
