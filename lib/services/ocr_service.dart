import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, PlatformException;
import 'package:path_provider/path_provider.dart';

import 'image_metadata.dart';

// Android's Tesseract renderer preserves page images and adds selectable text.
const _channel = MethodChannel('com.fosscanner.app/ocr');
bool _isCreatingPdf = false;
bool _cancellationRequested = false;
bool _nativeRendering = false;
void Function(int completed, int total)? _progressCallback;

bool get isSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> _ensureTessdata() async {
  await _channel.invokeMethod<void>('ensureTessdata');
}

Future<void> _handleNativeCall(MethodCall call) async {
  if (call.method != 'ocrProgress') return;
  final arguments = call.arguments;
  if (arguments is! Map) return;
  final completed = arguments['completed'];
  final total = arguments['total'];
  if (completed is int && total is int && total > 0) {
    _progressCallback?.call(completed, total);
  }
}

bool isCancellation(Object error) =>
    error is PlatformException && error.code == 'ocr_cancelled';

Future<void> cancelSearchablePdf() async {
  if (!_isCreatingPdf) return;
  _cancellationRequested = true;
  if (_nativeRendering) {
    await _channel.invokeMethod<void>('cancelSearchablePdf');
  }
}

void _checkCancellation() {
  if (_cancellationRequested) {
    throw PlatformException(
      code: 'ocr_cancelled',
      message: 'OCR export cancelled',
    );
  }
}

// Renders a multi-page searchable PDF (each page's image with an invisible,
// selectable OCR text layer, in the given order) using libtesseract's own
// native PDF renderer. Returns the finished PDF's bytes.
Future<Uint8List> createSearchablePdf(
  List<Uint8List> pageImages, {
  void Function(int completed, int total)? onProgress,
}) async {
  if (!isSupported) {
    throw UnsupportedError('Searchable PDF export requires Android');
  }
  if (_isCreatingPdf) throw StateError('An OCR export is already running');
  if (pageImages.isEmpty || pageImages.length > maxDocumentPages) {
    throw ArgumentError('OCR requires 1 to $maxDocumentPages pages');
  }
  final images = List<Uint8List>.of(pageImages, growable: false);
  var totalBytes = 0;
  for (final bytes in images) {
    if (bytes.isEmpty || bytes.length > maxEncodedImageBytes) {
      throw ArgumentError('OCR page exceeds the supported encoded size');
    }
    totalBytes += bytes.length;
    if (totalBytes > maxRetainedDocumentBytes) {
      throw ArgumentError('OCR document exceeds the supported byte limit');
    }
  }
  _isCreatingPdf = true;
  _cancellationRequested = false;
  _progressCallback = onProgress;
  _channel.setMethodCallHandler(_handleNativeCall);
  Directory? jobDirectory;
  try {
    late Uint8List pdfBytes;
    try {
      await _ensureTessdata();
      _checkCancellation();
      final tempDir = await getTemporaryDirectory();
      _checkCancellation();
      jobDirectory = await tempDir.createTemp('fosscanner_ocr_');
      _checkCancellation();
      final imageFiles = <File>[];
      for (var i = 0; i < images.length; i++) {
        final file = File('${jobDirectory.path}/page_$i.jpg');
        await file.writeAsBytes(images[i]);
        _checkCancellation();
        imageFiles.add(file);
      }
      final outputPathNoExtension = '${jobDirectory.path}/document';
      final pdfFile = File('$outputPathNoExtension.pdf');
      final String? pdfPath;
      _nativeRendering = true;
      try {
        pdfPath = await _channel.invokeMethod<String>('createSearchablePdf', {
          'imagePaths': [for (final file in imageFiles) file.path],
          'outputPath': outputPathNoExtension,
        });
      } finally {
        _nativeRendering = false;
      }
      _checkCancellation();
      if (pdfPath != pdfFile.path) {
        throw StateError(
          'Native searchable-PDF renderer returned an invalid path',
        );
      }
      final length = await pdfFile.length();
      _checkCancellation();
      if (length == 0 || length > maxRetainedDocumentBytes) {
        throw StateError('Searchable PDF exceeds the supported output size');
      }
      pdfBytes = await readBoundedBytes(
        pdfFile.openRead(),
        maxBytes: maxRetainedDocumentBytes,
      );
    } finally {
      // Includes partially written inputs and PDFs even when native rendering
      // fails before it returns a path. Native resources are already closed.
      try {
        if (jobDirectory != null) await jobDirectory.delete(recursive: true);
      } on FileSystemException {
        // Best effort; app/OS cache copies can persist if deletion fails.
      }
    }
    _checkCancellation();
    return pdfBytes;
  } catch (_) {
    // Cancellation wins over a late preparation/rendering failure, so the UI
    // does not offer a fallback for an export the user already cancelled.
    _checkCancellation();
    rethrow;
  } finally {
    _isCreatingPdf = false;
    _cancellationRequested = false;
    _progressCallback = null;
    _channel.setMethodCallHandler(null);
  }
}
