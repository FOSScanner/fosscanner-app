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

/// Assembles an image-only PDF, keeping only compressed page images.
///
/// [onProgress] reports finished pages; [isCancelled] is polled between them
/// and before assembly, so a cancelled export stops without encoding the rest
/// of the document. Page conversion and assembly run through [compute], which
/// uses a worker isolate on every platform that has one and falls back to the
/// calling isolate on web.
Future<Uint8List> createImageOnlyPdf(
  List<Uint8List> pages, {
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
  return compute(_assembleDocument, jpegPages);
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

Future<Uint8List> _assembleDocument(List<Uint8List> jpegPages) async {
  final pdf = pw.Document();
  for (final bytes in jpegPages) {
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
  return pdf.save();
}
