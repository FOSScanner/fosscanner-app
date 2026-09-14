import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const _scanDpi = 150.0;

/// Keeps only compressed page images while assembling an image-only PDF.
Future<Uint8List> createImageOnlyPdf(List<Uint8List> pages) async {
  final pdf = pw.Document();
  for (final bytes in pages) {
    // The PDF library retains raw RGB(A) buffers for non-JPEG images until
    // save(). Compress one page at a time so small PNG files cannot expand
    // into a document-sized collection of uncompressed pixel buffers.
    final image = pw.MemoryImage(_jpegPage(bytes));
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
    // Allow UI work between pages, including on web where worker isolates
    // are unavailable.
    await Future<void>.delayed(Duration.zero);
  }
  return pdf.save();
}

Uint8List _jpegPage(Uint8List bytes) {
  if (im.JpegDecoder().isValidFile(bytes)) return bytes;
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
