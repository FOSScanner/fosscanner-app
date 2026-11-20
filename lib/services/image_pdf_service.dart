import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_export_options.dart';

/// Thrown by [writeImageOnlyPdf] when its caller asked it to stop.
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
///
/// [pageSize] and [quality] choose the page box and image resolution; see
/// [planPdfPage]. The defaults reproduce the historical output exactly.
Future<void> writeImageOnlyPdf(
  List<Uint8List> pages,
  String outputPath, {
  PdfPageSize pageSize = PdfPageSize.original,
  PdfQuality quality = PdfQuality.high,
  void Function(int completed, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  try {
    await _writeImageOnlyPdf(
      pages,
      outputPath,
      pageSize: pageSize,
      quality: quality,
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
  required PdfPageSize pageSize,
  required PdfQuality quality,
  void Function(int completed, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final keepsOriginal =
      pageSize == PdfPageSize.original && quality == PdfQuality.high;
  final jpegPages = <_Page>[];
  for (final bytes in pages) {
    if (isCancelled?.call() ?? false) throw const ImagePdfCancelledException();
    // The PDF library retains raw RGB(A) buffers for non-JPEG images until
    // save(), so a small PNG file would expand into a page-sized uncompressed
    // pixel buffer held for the whole document. Scanner pages are already
    // JPEG and pass through untouched; anything else is re-encoded on a
    // worker, keeping both the decoded bitmap and the encoder off this
    // isolate.
    // Presets other than Original/High resample or re-encode on the worker
    // too, and return the page's placement with it.
    if (keepsOriginal && im.JpegDecoder().isValidFile(bytes)) {
      jpegPages.add((bytes: bytes, plan: null));
    } else {
      final prepared = await compute(preparePdfPage, (
        bytes: bytes,
        pageSize: pageSize,
        quality: quality,
        padToPage: false,
      ));
      jpegPages.add((bytes: prepared.bytes, plan: prepared.plan));
    }
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

/// A page image ready to embed; a null plan keeps the historical layout.
typedef _Page = ({Uint8List bytes, PdfPagePlan? plan});

Future<void> _assembleDocument(({List<_Page> pages, String path}) job) async {
  final pdf = pw.Document();
  for (final page in job.pages) {
    final image = pw.MemoryImage(page.bytes);
    final plan = page.plan;
    pdf.addPage(
      pw.Page(
        pageFormat: plan == null
            ? PdfPageFormat(
                image.width! / originalPageDpi * PdfPageFormat.inch,
                image.height! / originalPageDpi * PdfPageFormat.inch,
              )
            : PdfPageFormat(plan.pageWidth, plan.pageHeight),
        margin: pw.EdgeInsets.zero,
        build: (_) => plan == null
            ? pw.Image(image, fit: pw.BoxFit.fill)
            : pw.Center(
                child: pw.SizedBox(
                  width: plan.imageWidth,
                  height: plan.imageHeight,
                  child: pw.Image(image, fit: pw.BoxFit.fill),
                ),
              ),
      ),
    );
  }
  await File(job.path).writeAsBytes(await pdf.save(), flush: true);
}
