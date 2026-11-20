import 'dart:io';

import 'package:flutter/foundation.dart'
    show Uint8List, compute, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, PlatformException;
import 'package:path_provider/path_provider.dart';

import 'image_metadata.dart';
import 'pdf_export_options.dart';

// Android's Tesseract renderer preserves page images and adds selectable text.
// Keep the channel contract synchronized with MainActivity.kt.
const _channel = MethodChannel('com.fosscanner.app/ocr');
// One OCR job (searchable PDF or text copy) at a time; they share the native
// worker, its cancellation flag and the progress callback.
bool _isRunning = false;
bool _cancellationRequested = false;
bool _nativeRendering = false;
void Function(int completed, int total)? _progressCallback;

bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

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

/// Cancels the running OCR job, whether it renders a searchable PDF or
/// recognizes text to copy. A no-op when nothing is running.
Future<void> cancelOcrJob() async {
  if (!_isRunning) return;
  _cancellationRequested = true;
  if (_nativeRendering) {
    // The native method cancels whichever OCR job its worker is running.
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
// native PDF renderer, and moves the finished file to [outputPath]. The PDF is
// never read into the Dart heap. Whenever this throws, no file is left at
// [outputPath].
//
// [pageSize] and [quality] are applied before OCR: each page is resampled,
// and for A4/Letter centered on a white page-shaped canvas, on a worker, and
// its density is sent along because Tesseract sizes pages as pixels / DPI.
// Original/High sends the pages untouched at their source density
// ([sourceDpis], null for photos), or the historical 150 DPI without one.
Future<void> createSearchablePdf(
  List<Uint8List> pageImages, {
  required String outputPath,
  List<double?>? sourceDpis,
  PdfPageSize pageSize = PdfPageSize.original,
  PdfQuality quality = PdfQuality.high,
  void Function(int completed, int total)? onProgress,
}) async {
  final images = _validatedPages(pageImages);
  if (sourceDpis != null && sourceDpis.length != images.length) {
    throw ArgumentError('One source density per page');
  }
  _startJob(onProgress);
  Directory? jobDirectory;
  final output = File(outputPath);
  var moved = false;
  try {
    try {
      await _ensureTessdata();
      _checkCancellation();
      final tempDir = await getTemporaryDirectory();
      _checkCancellation();
      jobDirectory = await tempDir.createTemp('fosscanner_ocr_');
      _checkCancellation();
      final keepsOriginal =
          pageSize == PdfPageSize.original && quality == PdfQuality.high;
      final imageFiles = <File>[];
      final pageDpis = <int>[];
      for (var i = 0; i < images.length; i++) {
        var bytes = images[i];
        final sourceDpi = sourceDpis?[i];
        var dpi = originalDensity(sourceDpi);
        if (!keepsOriginal) {
          final prepared = await compute(preparePdfPage, (
            bytes: bytes,
            pageSize: pageSize,
            quality: quality,
            padToPage: true,
            sourceDpi: sourceDpi,
          ));
          _checkCancellation();
          bytes = prepared.bytes;
          dpi = prepared.plan.nativeDpi;
        }
        final file = File('${jobDirectory.path}/page_$i.jpg');
        await file.writeAsBytes(bytes);
        _checkCancellation();
        imageFiles.add(file);
        pageDpis.add(dpi);
      }
      final outputPathNoExtension = '${jobDirectory.path}/document';
      final pdfFile = File('$outputPathNoExtension.pdf');
      final String? pdfPath;
      _nativeRendering = true;
      try {
        pdfPath = await _channel.invokeMethod<String>('createSearchablePdf', {
          'imagePaths': [for (final file in imageFiles) file.path],
          'outputPath': outputPathNoExtension,
          'pageDpis': pageDpis,
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
      await _move(pdfFile, output);
      moved = true;
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
  } catch (_) {
    if (moved) await _deleteQuietly(output);
    // Cancellation wins over a late preparation/rendering failure, so the UI
    // does not offer a fallback for an export the user already cancelled.
    _checkCancellation();
    rethrow;
  } finally {
    _finishJob();
  }
}

/// Recognizes the text of every page, in order, on the native OCR worker and
/// puts it on the system clipboard, marked sensitive where Android supports
/// it. Returns the number of characters copied; 0 means no text was found and
/// the clipboard was left untouched.
///
/// The text is written to the clipboard natively and never crosses the
/// channel or reaches a log. Pages are recognized as they are, without the
/// PDF page-size and quality presets. Throws a cancellation (see
/// [isCancellation]) after [cancelOcrJob].
Future<int> copyRecognizedText(
  List<Uint8List> pageImages, {
  void Function(int completed, int total)? onProgress,
}) async {
  final images = _validatedPages(pageImages);
  _startJob(onProgress);
  Directory? jobDirectory;
  try {
    try {
      await _ensureTessdata();
      _checkCancellation();
      final tempDir = await getTemporaryDirectory();
      _checkCancellation();
      jobDirectory = await tempDir.createTemp('fosscanner_ocr_');
      _checkCancellation();
      final imagePaths = <String>[];
      for (var i = 0; i < images.length; i++) {
        final file = File('${jobDirectory.path}/page_$i.jpg');
        await file.writeAsBytes(images[i]);
        _checkCancellation();
        imagePaths.add(file.path);
      }
      final int? copied;
      _nativeRendering = true;
      try {
        copied = await _channel.invokeMethod<int>('copyRecognizedText', {
          'imagePaths': imagePaths,
        });
      } finally {
        _nativeRendering = false;
      }
      if (copied == null || copied < 0) {
        throw StateError('Native text recognition returned an invalid result');
      }
      return copied;
    } finally {
      try {
        if (jobDirectory != null) await jobDirectory.delete(recursive: true);
      } on FileSystemException {
        // Best effort; app/OS cache copies can persist if deletion fails.
      }
    }
  } catch (_) {
    // A late failure after the user cancelled is reported as the cancel.
    _checkCancellation();
    rethrow;
  } finally {
    _finishJob();
  }
}

List<Uint8List> _validatedPages(List<Uint8List> pageImages) {
  if (!isSupported) {
    throw UnsupportedError('On-device text recognition requires Android');
  }
  if (_isRunning) throw StateError('An OCR job is already running');
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
  return images;
}

void _startJob(void Function(int completed, int total)? onProgress) {
  _isRunning = true;
  _cancellationRequested = false;
  _progressCallback = onProgress;
  _channel.setMethodCallHandler(_handleNativeCall);
}

void _finishJob() {
  _isRunning = false;
  _cancellationRequested = false;
  _progressCallback = null;
  _channel.setMethodCallHandler(null);
}

// Both paths are in the app cache, so this is normally a rename. The copy only
// covers a platform that splits the cache across file systems.
Future<void> _move(File source, File destination) async {
  try {
    await source.rename(destination.path);
  } on FileSystemException {
    try {
      await source.copy(destination.path);
    } catch (_) {
      await _deleteQuietly(destination);
      rethrow;
    }
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Already gone, or left for the caller's directory cleanup.
  }
}
