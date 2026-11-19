import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const _scanDpi = 150.0;

/// Thrown by [createImageOnlyPdf] when its caller asked it to stop.
class ImagePdfCancelledException implements Exception {
  const ImagePdfCancelledException();
}

/// Assembles an image-only PDF at [outputPath], keeping only compressed page
/// images.
///
/// The worker that assembles the document also writes it, so the finished
/// PDF never crosses into the calling isolate's heap. Whenever this throws,
/// including on cancellation, no file is left at [outputPath].
///
/// [onProgress] reports finished pages; [isCancelled] is polled between them,
/// before assembly and once more after it, so a cancelled export stops without
/// encoding the rest of the document and never hands back one it finished
/// after the caller gave up. Page conversion and assembly run through
/// [compute], which uses a worker isolate on every platform that has one and
/// falls back to the calling isolate on web.
Future<void> writeImageOnlyPdf(
  List<Uint8List> pages,
  String outputPath, {
  void Function(int completed, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  try {
    await _writeImageOnlyPdf(
      pages,
      outputPath,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  } catch (_) {
    try {
      await File(outputPath).delete();
    } on FileSystemException {
      // Nothing was written, or the caller's directory cleanup removes it.
    }
    rethrow;
  }
}

Future<void> _writeImageOnlyPdf(
  List<Uint8List> pages,
  String outputPath, {
  void Function(int completed, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final jpegPages = <Uint8List>[];
  for (final bytes in pages) {
    if (isCancelled?.call() ?? false) throw const ImagePdfCancelledException();
    // The PDF library retains raw RGB(A) buffers for non-JPEG images until
    // save(), so a small PNG file would expand into a page-sized uncompressed
    // pixel buffer held for the whole document. Scanner pages are already
    // JPEG and pass through untouched; anything else is re-encoded on a
    // worker, keeping both the decoded bitmap and the encoder off this
    // isolate.
    jpegPages.add(
      im.JpegDecoder().isValidFile(bytes)
          ? bytes
          : await compute(_encodeJpegPage, bytes),
    );
    onProgress?.call(jpegPages.length, pages.length);
  }
  if (isCancelled?.call() ?? false) throw const ImagePdfCancelledException();
  // Assembly is the one step that holds every page at once and deflates the
  // document around them, so it does not belong on the UI isolate either.
  await compute(_assembleDocument, (pages: jpegPages, path: outputPath));
  // Assembly cannot be interrupted once handed to the worker, so a cancel
  // arriving while it runs is only observable here. Report it rather than
  // returning a document the caller would go on to share.
  if (isCancelled?.call() ?? false) throw const ImagePdfCancelledException();
}

// Re-encodes one page as an opaque JPEG. Top-level so compute can run it.
Uint8List _encodeJpegPage(Uint8List bytes) {
  final decoded = im.decodeImage(bytes, frame: 0);
  if (decoded == null) throw const FormatException('Could not decode PDF page');
  var opaque = decoded;
  if (decoded.hasAlpha) {
    opaque = im.Image(
      width: decoded.width,
      height: decoded.height,
      numChannels: 3,
    );
    im.fill(opaque, color: im.ColorRgb8(255, 255, 255));
    im.compositeImage(opaque, decoded);
  }
  return im.encodeJpg(opaque, quality: 95);
}

Future<void> _assembleDocument(
  ({List<Uint8List> pages, String path}) job,
) async {
  final pdf = pw.Document();
  for (final bytes in job.pages) {
    final image = pw.MemoryImage(bytes);
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          image.width! / _scanDpi * PdfPageFormat.inch,
          image.height! / _scanDpi * PdfPageFormat.inch,
        ),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
      ),
    );
  }
  await File(job.path).writeAsBytes(await pdf.save(), flush: true);
}
