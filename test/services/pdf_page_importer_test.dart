import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/services/corner_geometry.dart' show maxWarpPixels;
import 'package:fosscanner/services/image_metadata.dart';
import 'package:fosscanner/services/pdf_export_options.dart';
import 'package:fosscanner/services/pdf_page_importer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PdfImportRequest.forDocument', () {
    test('derives the density from the quality preset', () {
      expect(pdfImportDpi(PdfQuality.high), 300);
      expect(pdfImportDpi(PdfQuality.balanced), 200);
      expect(pdfImportDpi(PdfQuality.small), 150);
      final request = PdfImportRequest.forDocument(
        quality: PdfQuality.balanced,
        currentPages: 0,
        retainedBytes: 0,
      )!;
      expect(request.dpi, 200);
      expect(request.jpegQuality, 85);
      expect(
        PdfImportRequest.forDocument(
          quality: PdfQuality.high,
          currentPages: 0,
          retainedBytes: 0,
        )!.jpegQuality,
        95,
      );
    });

    test('limits pages and bytes to what the document can still hold', () {
      final request = PdfImportRequest.forDocument(
        quality: PdfQuality.high,
        currentPages: 97,
        retainedBytes: 200 * 1024 * 1024,
      )!;
      expect(request.maxPages, 3);
      expect(
        request.maxTotalBytes,
        maxRetainedDocumentBytes - 200 * 1024 * 1024,
      );
    });

    test('caps page pixels by the source limit and processing budget', () {
      final empty = PdfImportRequest.forDocument(
        quality: PdfQuality.high,
        currentPages: 0,
        retainedBytes: 0,
      )!;
      expect(empty.maxPagePixels, maxSourceImagePixels);

      for (final retained in [
        64 * 1024 * 1024,
        100 * 1024 * 1024,
        200 * 1024 * 1024,
        250 * 1024 * 1024,
      ]) {
        final request = PdfImportRequest.forDocument(
          quality: PdfQuality.high,
          currentPages: 1,
          retainedBytes: retained,
        )!;
        final pixels = request.maxPagePixels;
        expect(pixels, lessThanOrEqualTo(maxSourceImagePixels));
        // A page at the cap, with about one encoded byte per pixel, still
        // passes the admission check that runs before its review.
        final estimate =
            retained +
            pixels +
            pixels * 4 +
            (pixels < maxWarpPixels ? pixels : maxWarpPixels) * 16;
        expect(
          estimate,
          lessThanOrEqualTo(maxImageProcessingWorkingSetBytes),
          reason: '$pixels pixels at $retained retained bytes',
        );
      }
    });

    test('a large photo document still renders A4 pages at 300 DPI', () {
      // About what 97 photo pages retained when the resolution dropped from
      // 2478 to 1822 px wide.
      final request = PdfImportRequest.forDocument(
        quality: PdfQuality.high,
        currentPages: 97,
        retainedBytes: 160 * 1024 * 1024,
      )!;
      expect(request.dpi, 300);
      expect(request.maxPagePixels, greaterThanOrEqualTo(2479 * 3508));
    });

    test('returns null when nothing more fits', () {
      expect(
        PdfImportRequest.forDocument(
          quality: PdfQuality.high,
          currentPages: maxDocumentPages,
          retainedBytes: 0,
        ),
        isNull,
      );
      expect(
        PdfImportRequest.forDocument(
          quality: PdfQuality.high,
          currentPages: 1,
          retainedBytes: maxRetainedDocumentBytes,
        ),
        isNull,
      );
    });
  });

  group('MethodChannelPdfPageImporter', () {
    const channel = MethodChannelPdfPageImporter.channel;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      calls.clear();
    });

    const request = PdfImportRequest(
      dpi: 300,
      maxPages: 4,
      maxPagePixels: 1000000,
      maxTotalBytes: 2048,
      jpegQuality: 90,
    );

    Future<void> sendProgress(int completed, int total) =>
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('pdfImportProgress', {
              'completed': completed,
              'total': total,
            }),
          ),
          (_) {},
        );

    test('picks, renders with progress and decodes the reply', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'pickPdf') return true;
        if (call.method == 'renderPdf') {
          await sendProgress(0, 2);
          await sendProgress(2, 2);
          return {
            'paths': ['/cache/page_0.jpg', 7, '', '/cache/page_1.jpg'],
            'pageCount': 9,
            'rejected': 1,
            'truncated': true,
          };
        }
        return null;
      });
      final importer = MethodChannelPdfPageImporter.instance;
      expect(await importer.pickDocument(), isTrue);
      final progress = <(int, int)>[];
      final batch = await importer.renderPages(
        request,
        onProgress: (completed, total) => progress.add((completed, total)),
      );
      expect(calls.map((call) => call.method), ['pickPdf', 'renderPdf']);
      expect(calls.last.arguments, {
        'dpi': 300,
        'maxPages': 4,
        'maxPagePixels': 1000000,
        'maxTotalBytes': 2048,
        'jpegQuality': 90,
      });
      expect(progress, [(0, 2), (2, 2)]);
      expect(batch.paths, ['/cache/page_0.jpg', '/cache/page_1.jpg']);
      expect(batch.pageCount, 9);
      expect(batch.rejected, 1);
      expect(batch.truncated, isTrue);
    });

    test('a cancelled picker reports false', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(
        await MethodChannelPdfPageImporter.instance.pickDocument(),
        isFalse,
      );
    });

    test('maps platform errors without exposing their details', () async {
      for (final (code, failure) in [
        ('pdf_unreadable', PdfImportFailure.unreadable),
        ('pdf_cancelled', PdfImportFailure.cancelled),
        ('pdf_memory', PdfImportFailure.failed),
        ('pdf_failed', PdfImportFailure.failed),
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: code, message: 'content://secret');
        });
        await expectLater(
          MethodChannelPdfPageImporter.instance.renderPages(request),
          throwsA(
            isA<PdfImportException>()
                .having((error) => error.failure, 'failure', failure)
                .having((error) => '$error', 'text', isNot(contains('secret'))),
          ),
        );
      }
    });

    test('cancel reaches the platform', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await MethodChannelPdfPageImporter.instance.cancel();
      expect(calls.single.method, 'cancelPdfImport');
    });

    test('malformed replies decode to nothing', () {
      final empty = parsePdfImportBatch(null);
      expect(empty.paths, isEmpty);
      final batch = parsePdfImportBatch({
        'paths': 'nope',
        'pageCount': -3,
        'rejected': 'x',
        'truncated': 1,
        'reduced': 'yes',
      });
      expect(batch.paths, isEmpty);
      expect(batch.pageCount, 0);
      expect(batch.rejected, 0);
      expect(batch.truncated, isFalse);
      expect(batch.reduced, isFalse);
      expect(parsePdfImportBatch({'reduced': true}).reduced, isTrue);
    });
  });
}
