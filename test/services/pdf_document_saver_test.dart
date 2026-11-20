import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/pdf_document_saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fosscanner.app/ocr');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Object? Function(MethodCall) reply;
  const saver = PlatformPdfDocumentSaver();
  final pdf = File('/cache/fosscanner_export_x/Scan 2026-11-19 14-05.pdf');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    reply = (_) => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('sends the exported path and suggested name', () async {
    expect(
      await saver.save(pdf, fileName: 'Scan 2026-11-19 14-05.pdf'),
      isTrue,
    );
    expect(calls.single.method, 'savePdfDocument');
    expect(calls.single.arguments, {
      'sourcePath': pdf.path,
      'fileName': 'Scan 2026-11-19 14-05.pdf',
    });
  });

  test('a cancelled picker reports false', () async {
    reply = (_) => false;
    expect(await saver.save(pdf, fileName: 'a.pdf'), isFalse);
    reply = (_) => null;
    expect(await saver.save(pdf, fileName: 'a.pdf'), isFalse);
  });

  test('native failures propagate to the caller', () async {
    reply = (_) => throw PlatformException(code: 'save_failed');
    await expectLater(
      saver.save(pdf, fileName: 'a.pdf'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('is offered on Android only', () async {
    expect(saver.isSupported, isTrue);
    for (final platform in [TargetPlatform.iOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(saver.isSupported, isFalse);
      await expectLater(
        saver.save(pdf, fileName: 'a.pdf'),
        throwsUnsupportedError,
      );
    }
    expect(calls, isEmpty);
  });
}
