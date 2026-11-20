import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gives every test its own path_provider directory.
///
/// PDF export writes its output into the app cache before sharing it, so any
/// test that exports needs path_provider. Tests that care about the directory
/// install their own handler, which replaces this one until their tear-down.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  Directory? directory;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final current = directory = Directory.systemTemp.createTempSync(
      'fosscanner_test_paths_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => current.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    try {
      directory?.deleteSync(recursive: true);
    } on FileSystemException {
      // A test may already have removed it.
    }
    directory = null;
  });

  await testMain();
}
