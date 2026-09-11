import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/image_metadata.dart';
import 'package:fosscanner/services/ocr_service.dart' as ocr;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fosscanner.app/ocr');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) render;
  final page = Uint8List.fromList([1, 2, 3]);
  final pdf = Uint8List.fromList('%PDF-1.5\nfixture\n%%EOF'.codeUnits);

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    temporary = await Directory.systemTemp.createTemp('ocr_test_');
    calls = [];
    messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
    render = (call) async {
      final args = call.arguments as Map;
      final output = File('${args['outputPath']}.pdf');
      await output.writeAsBytes(pdf);
      return output.path;
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ensureTessdata') return null;
      return render(call);
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(paths, null);
    debugDefaultTargetPlatformOverride = null;
    await temporary.delete(recursive: true);
  });

  test(
    'exports ordered bytes and removes its entire working directory',
    () async {
      final second = Uint8List.fromList([4, 5, 6]);
      render = (call) async {
        final args = call.arguments as Map;
        final inputs = (args['imagePaths'] as List).cast<String>();
        expect(await File(inputs[0]).readAsBytes(), page);
        expect(await File(inputs[1]).readAsBytes(), second);
        final output = File('${args['outputPath']}.pdf');
        expect(output.parent.path, File(inputs[0]).parent.path);
        await output.writeAsBytes(pdf);
        return output.path;
      };
      expect(await ocr.createSearchablePdf([page, second]), pdf);
      expect(calls.map((call) => call.method), [
        'ensureTessdata',
        'createSearchablePdf',
      ]);
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  test(
    'removes a partial PDF when native rendering fails and allows retry',
    () async {
      render = (call) async {
        await File(
          '${(call.arguments as Map)['outputPath']}.pdf',
        ).writeAsBytes(pdf);
        throw PlatformException(code: 'ocr_failed');
      };
      await expectLater(
        ocr.createSearchablePdf([page]),
        throwsA(isA<PlatformException>()),
      );
      expect(await temporary.list().toList(), isEmpty);
      render = (call) async {
        final output = File('${(call.arguments as Map)['outputPath']}.pdf');
        await output.writeAsBytes(pdf);
        return output.path;
      };
      expect(await ocr.createSearchablePdf([page]), pdf);
    },
  );

  test(
    'rejects unexpected paths without reading or deleting external files',
    () async {
      final outside = File('${temporary.path}/original.pdf');
      await outside.writeAsBytes(pdf);
      render = (_) async => outside.path;
      await expectLater(ocr.createSearchablePdf([page]), throwsStateError);
      expect(await outside.readAsBytes(), pdf);
      expect(await temporary.list().length, 1);
    },
  );

  test(
    'cleans up when the renderer returns no path or a missing PDF',
    () async {
      render = (_) async => null;
      await expectLater(ocr.createSearchablePdf([page]), throwsStateError);
      expect(await temporary.list().toList(), isEmpty);
      render = (call) async => '${(call.arguments as Map)['outputPath']}.pdf';
      await expectLater(
        ocr.createSearchablePdf([page]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  test('bounds output before reading it into memory', () async {
    render = (call) async {
      final output = File('${(call.arguments as Map)['outputPath']}.pdf');
      final handle = await output.open(mode: FileMode.write);
      try {
        await handle.truncate(maxRetainedDocumentBytes + 1);
      } finally {
        await handle.close();
      }
      return output.path;
    };
    await expectLater(ocr.createSearchablePdf([page]), throwsStateError);
    expect(await temporary.list().toList(), isEmpty);
  });

  test(
    'rejects concurrent exports and snapshots page order before awaiting',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      final images = [page];
      render = (call) async {
        started.complete();
        await finish.future;
        expect((call.arguments as Map)['imagePaths'], hasLength(1));
        final output = File('${(call.arguments as Map)['outputPath']}.pdf');
        await output.writeAsBytes(pdf);
        return output.path;
      };
      final first = ocr.createSearchablePdf(images);
      images.clear();
      await started.future;
      try {
        await expectLater(ocr.createSearchablePdf([page]), throwsStateError);
      } finally {
        finish.complete();
      }
      expect(await first, pdf);
    },
  );

  test('model installation failure releases the busy guard', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'invalid_model');
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        ocr.createSearchablePdf([page]),
        throwsA(isA<PlatformException>()),
      );
    }
    expect(await temporary.list().toList(), isEmpty);
  });

  test(
    'rejects unsupported platforms and invalid inputs before the channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await expectLater(
        ocr.createSearchablePdf([page]),
        throwsUnsupportedError,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await expectLater(ocr.createSearchablePdf([]), throwsArgumentError);
      await expectLater(
        ocr.createSearchablePdf([Uint8List(0)]),
        throwsArgumentError,
      );
      await expectLater(
        ocr.createSearchablePdf(List.filled(maxDocumentPages + 1, page)),
        throwsArgumentError,
      );
      await expectLater(
        ocr.createSearchablePdf([Uint8List(maxEncodedImageBytes + 1)]),
        throwsArgumentError,
      );
      final large = Uint8List(maxEncodedImageBytes);
      await expectLater(
        ocr.createSearchablePdf(List.filled(9, large)),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );
}
