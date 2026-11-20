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
    reply = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('chooses a location, then writes the exported path', () async {
    reply = (call) =>
        call.method == 'chooseSaveTarget' ? {'fileName': 'Taxes.pdf'} : null;
    final target = await saver.chooseTarget(
      fileName: 'Scan 2026-11-19 14-05.pdf',
    );
    expect(target!.fileName, 'Taxes.pdf');
    await target.write(pdf);
    expect(calls.map((call) => call.method), [
      'chooseSaveTarget',
      'writeSaveTarget',
    ]);
    expect(calls.first.arguments, {'fileName': 'Scan 2026-11-19 14-05.pdf'});
    expect(calls.last.arguments, {'sourcePath': pdf.path});
  });

  test('without a reported name the suggestion is kept', () async {
    for (final answer in [
      <String, Object?>{},
      {'fileName': null},
      true,
    ]) {
      reply = (_) => answer;
      final target = await saver.chooseTarget(fileName: 'a.pdf');
      expect(target!.fileName, 'a.pdf');
    }
  });

  test('a cancelled picker reports null', () async {
    reply = (_) => null;
    expect(await saver.chooseTarget(fileName: 'a.pdf'), isNull);
  });

  test('discarding asks the platform and never throws', () async {
    reply = (call) => call.method == 'chooseSaveTarget'
        ? {'fileName': 'a.pdf'}
        : throw PlatformException(code: 'x');
    final target = await saver.chooseTarget(fileName: 'a.pdf');
    await target!.discard();
    expect(calls.last.method, 'discardSaveTarget');
  });

  test('native failures propagate to the caller', () async {
    reply = (_) => throw PlatformException(code: 'save_busy');
    await expectLater(
      saver.chooseTarget(fileName: 'a.pdf'),
      throwsA(isA<PlatformException>()),
    );
    reply = (call) => call.method == 'chooseSaveTarget'
        ? {'fileName': 'a.pdf'}
        : throw PlatformException(code: 'save_failed');
    final target = await saver.chooseTarget(fileName: 'a.pdf');
    await expectLater(target!.write(pdf), throwsA(isA<PlatformException>()));
  });

  test('is offered on Android only', () async {
    expect(saver.isSupported, isTrue);
    for (final platform in [TargetPlatform.iOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(saver.isSupported, isFalse);
      await expectLater(
        saver.chooseTarget(fileName: 'a.pdf'),
        throwsUnsupportedError,
      );
    }
    expect(calls, isEmpty);
  });
}
