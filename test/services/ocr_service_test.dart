import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/image_metadata.dart';
import 'package:fosscanner/services/ocr_service.dart' as ocr;
import 'package:fosscanner/services/pdf_export_options.dart';
import 'package:image/image.dart' as im;

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
  late Directory outputs;
  String outputPath() => '${outputs.path}/export.pdf';
  Future<void> create(List<Uint8List> images) =>
      ocr.createSearchablePdf(images, outputPath: outputPath());
  Future<Uint8List> readOutput() async {
    final output = File(outputPath());
    final bytes = await output.readAsBytes();
    await output.delete();
    return bytes;
  }

  Future<Uint8List> exportPdf(List<Uint8List> images) async {
    await create(images);
    return readOutput();
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    temporary = await Directory.systemTemp.createTemp('ocr_test_');
    outputs = await Directory.systemTemp.createTemp('ocr_output_');
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
      if (call.method == 'cancelSearchablePdf') return null;
      return render(call);
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(paths, null);
    debugDefaultTargetPlatformOverride = null;
    await temporary.delete(recursive: true);
    // Failed and cancelled exports never leave a file at the output path;
    // successful ones are read back and removed by the test.
    expect(outputs.listSync(), isEmpty);
    await outputs.delete();
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
      expect(await exportPdf([page, second]), pdf);
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
      await expectLater(create([page]), throwsA(isA<PlatformException>()));
      expect(await temporary.list().toList(), isEmpty);
      render = (call) async {
        final output = File('${(call.arguments as Map)['outputPath']}.pdf');
        await output.writeAsBytes(pdf);
        return output.path;
      };
      expect(await exportPdf([page]), pdf);
    },
  );

  test(
    'rejects unexpected paths without reading or deleting external files',
    () async {
      final outside = File('${temporary.path}/original.pdf');
      await outside.writeAsBytes(pdf);
      render = (_) async => outside.path;
      await expectLater(create([page]), throwsStateError);
      expect(await outside.readAsBytes(), pdf);
      expect(await temporary.list().length, 1);
    },
  );

  test(
    'cleans up when the renderer returns no path or a missing PDF',
    () async {
      render = (_) async => null;
      await expectLater(create([page]), throwsStateError);
      expect(await temporary.list().toList(), isEmpty);
      render = (call) async => '${(call.arguments as Map)['outputPath']}.pdf';
      await expectLater(create([page]), throwsA(isA<FileSystemException>()));
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
    await expectLater(create([page]), throwsStateError);
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
      final first = create(images);
      images.clear();
      await started.future;
      try {
        await expectLater(create([page]), throwsStateError);
      } finally {
        finish.complete();
      }
      await first;
      expect(await readOutput(), pdf);
    },
  );

  test('discards native success after cancellation and cleans up', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    render = (call) async {
      started.complete();
      await finish.future;
      final output = File('${(call.arguments as Map)['outputPath']}.pdf');
      await output.writeAsBytes(pdf);
      return output.path;
    };

    final first = create([page]);
    final cancelled = expectLater(
      first,
      throwsA(predicate(ocr.isCancellation)),
    );
    await started.future;
    await ocr.cancelOcrJob();
    expect(calls.last.method, 'cancelSearchablePdf');
    finish.complete();
    await cancelled;
    expect(await temporary.list().toList(), isEmpty);
  });

  for (final failInstallation in [false, true]) {
    test(
      'cancels during model installation (failure: $failInstallation)',
      () async {
        final started = Completer<void>();
        final finish = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'ensureTessdata') {
            started.complete();
            await finish.future;
            if (failInstallation) {
              throw PlatformException(code: 'invalid_model');
            }
            return null;
          }
          if (call.method == 'cancelSearchablePdf') return null;
          return render(call);
        });
        final export = create([page]);
        final cancelled = expectLater(
          export,
          throwsA(predicate(ocr.isCancellation)),
        );
        await started.future;
        await ocr.cancelOcrJob();
        finish.complete();
        await cancelled;
        expect(
          calls.where((call) => call.method == 'createSearchablePdf'),
          isEmpty,
        );
        expect(await temporary.list().toList(), isEmpty);

        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'ensureTessdata') return null;
          return render(call);
        });
        expect(await exportPdf([page]), pdf);
      },
    );
  }

  test('cancels while waiting for the staging directory', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    messenger.setMockMethodCallHandler(paths, (_) async {
      started.complete();
      await finish.future;
      return temporary.path;
    });
    final export = create([page]);
    final cancelled = expectLater(
      export,
      throwsA(predicate(ocr.isCancellation)),
    );
    await started.future;
    await ocr.cancelOcrJob();
    finish.complete();
    await cancelled;
    expect(
      calls.where((call) => call.method == 'createSearchablePdf'),
      isEmpty,
    );
    expect(await temporary.list().toList(), isEmpty);
  });

  test('model installation failure releases the busy guard', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'invalid_model');
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(create([page]), throwsA(isA<PlatformException>()));
    }
    expect(await temporary.list().toList(), isEmpty);
  });

  test(
    'rejects unsupported platforms and invalid inputs before the channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await expectLater(create([page]), throwsUnsupportedError);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await expectLater(create([]), throwsArgumentError);
      await expectLater(create([Uint8List(0)]), throwsArgumentError);
      await expectLater(
        create(List.filled(maxDocumentPages + 1, page)),
        throwsArgumentError,
      );
      await expectLater(
        create([Uint8List(maxEncodedImageBytes + 1)]),
        throwsArgumentError,
      );
      final large = Uint8List(maxEncodedImageBytes);
      await expectLater(create(List.filled(9, large)), throwsArgumentError);
      expect(calls, isEmpty);
    },
  );

  test('sends the historical density for Original/High pages', () async {
    expect(await exportPdf([page, page]), pdf);
    final render = calls.singleWhere((c) => c.method == 'createSearchablePdf');
    expect((render.arguments as Map)['pageDpis'], [150, 150]);
  });

  test(
    'A4 pages are padded to the page shape with a matching density',
    () async {
      final jpeg = im.encodeJpg(im.Image(width: 300, height: 200));
      late List<int> dpis;
      late List<(int, int)> sizes;
      render = (call) async {
        final args = call.arguments as Map;
        dpis = (args['pageDpis'] as List).cast<int>();
        sizes = [
          for (final path in (args['imagePaths'] as List).cast<String>())
            () {
              final decoded = im.decodeJpg(File(path).readAsBytesSync())!;
              return (decoded.width, decoded.height);
            }(),
        ];
        final output = File('${args['outputPath']}.pdf');
        await output.writeAsBytes(pdf);
        return output.path;
      };
      await ocr.createSearchablePdf(
        [jpeg],
        outputPath: outputPath(),
        pageSize: PdfPageSize.a4,
        quality: PdfQuality.small,
      );
      await readOutput();
      final expected = planPdfPage(
        sourceWidth: 300,
        sourceHeight: 200,
        pageSize: PdfPageSize.a4,
        quality: PdfQuality.small,
      );
      expect(dpis, [expected.nativeDpi]);
      expect(sizes, [(expected.canvasWidth!, expected.canvasHeight!)]);
      // Landscape A4: the rendered page is pixels / DPI.
      expect(sizes.single.$1 / dpis.single * 72, closeTo(841.89, 1));
      expect(sizes.single.$2 / dpis.single * 72, closeTo(595.28, 1));
    },
  );

  group('copyRecognizedText', () {
    test('sends ordered pages, reports progress and cleans up', () async {
      final second = Uint8List.fromList([4, 5, 6]);
      final progress = <(int, int)>[];
      render = (call) async {
        expect(call.method, 'copyRecognizedText');
        final args = call.arguments as Map;
        // Only page paths cross the channel; the text never comes back.
        expect(args.keys, ['imagePaths']);
        final inputs = (args['imagePaths'] as List).cast<String>();
        expect(inputs.map((path) => path.split('/').last), [
          'page_0.jpg',
          'page_1.jpg',
        ]);
        expect(await File(inputs[0]).readAsBytes(), page);
        expect(await File(inputs[1]).readAsBytes(), second);
        await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            const MethodCall('ocrProgress', {'completed': 1, 'total': 2}),
          ),
          (_) {},
        );
        return 42;
      };

      final copied = await ocr.copyRecognizedText([
        page,
        second,
      ], onProgress: (completed, total) => progress.add((completed, total)));

      expect(copied, 42);
      expect(progress, [(1, 2)]);
      expect(calls.first.method, 'ensureTessdata');
      expect(await temporary.list().toList(), isEmpty);
    });

    test('reports no text as zero characters', () async {
      render = (_) async => 0;
      expect(await ocr.copyRecognizedText([page]), 0);
    });

    test('rejects a malformed native result', () async {
      render = (_) async => null;
      await expectLater(
        ocr.copyRecognizedText([page]),
        throwsA(isA<StateError>()),
      );
      expect(await temporary.list().toList(), isEmpty);
    });

    test('native failures surface and free the job slot', () async {
      render = (_) async => throw PlatformException(code: 'ocr_failed');
      await expectLater(
        ocr.copyRecognizedText([page]),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'ocr_failed'),
        ),
      );
      render = (_) async => 7;
      expect(await ocr.copyRecognizedText([page]), 7);
    });

    test('cancels the native worker and reports a cancellation', () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      render = (call) async {
        started.complete();
        await finish.future;
        throw PlatformException(code: 'ocr_cancelled');
      };
      final copy = ocr.copyRecognizedText([page]);
      final cancelled = expectLater(
        copy,
        throwsA(predicate(ocr.isCancellation)),
      );
      await started.future;
      await ocr.cancelOcrJob();
      expect(calls.last.method, 'cancelSearchablePdf');
      finish.complete();
      await cancelled;
      expect(await temporary.list().toList(), isEmpty);
    });

    test('shares the single OCR job slot with PDF export', () async {
      final finish = Completer<void>();
      render = (call) async {
        await finish.future;
        return 1;
      };
      final copy = ocr.copyRecognizedText([page]);
      await expectLater(
        ocr.copyRecognizedText([page]),
        throwsA(isA<StateError>()),
      );
      await expectLater(create([page]), throwsA(isA<StateError>()));
      finish.complete();
      expect(await copy, 1);
    });

    test('validates pages before touching the channel', () async {
      await expectLater(
        ocr.copyRecognizedText(const []),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        ocr.copyRecognizedText([Uint8List(0)]),
        throwsA(isA<ArgumentError>()),
      );
      expect(calls, isEmpty);
    });
  });
}
