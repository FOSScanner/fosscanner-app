import 'dart:math' as math;

import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, PlatformException;

import '../models/scanned_page.dart' show validSourceDpi;
import 'corner_geometry.dart' show maxWarpPixels;
import 'image_metadata.dart';
import 'pdf_export_options.dart';

/// Limits for rasterizing one PDF, derived from the quality preset and from
/// what the current document can still hold.
class PdfImportRequest {
  const PdfImportRequest({
    required this.dpi,
    required this.maxPages,
    required this.maxPagePixels,
    required this.maxTotalBytes,
    required this.jpegQuality,
  });

  /// Limits for a document with [currentPages] pages retaining
  /// [retainedBytes], or null when not even one small page would fit.
  ///
  /// The pixel cap keeps every rendered page within the source-image limits
  /// and within the processing budget [canProcessSourceImage] enforces before
  /// review, so pages are never rendered only to be rejected.
  static PdfImportRequest? forDocument({
    required PdfQuality quality,
    required int currentPages,
    required int retainedBytes,
  }) {
    final maxPages = maxDocumentPages - currentPages;
    final maxTotalBytes = availableEncodedImageBytes(
      currentBytes: retainedBytes,
      maxImageBytes: maxRetainedDocumentBytes,
    );
    final maxPagePixels = math.min(
      maxSourceImagePixels,
      _processablePixels(maxImageProcessingWorkingSetBytes - retainedBytes),
    );
    if (maxPages <= 0 || maxTotalBytes <= 0 || maxPagePixels < 9) return null;
    return PdfImportRequest(
      dpi: pdfImportDpi(quality),
      maxPages: maxPages,
      maxPagePixels: maxPagePixels,
      maxTotalBytes: maxTotalBytes,
      // Pages are encoded again on export; keep the intermediate copy sharp.
      jpegQuality: math.max(85, quality.jpegQuality),
    );
  }

  /// Render density in dots per inch.
  final int dpi;

  /// Pages the document can still accept.
  final int maxPages;

  /// Largest page bitmap that can still be reviewed, in pixels.
  final int maxPagePixels;

  /// Encoded bytes the document can still retain, across all pages.
  final int maxTotalBytes;

  final int jpegQuality;

  Map<String, Object> toChannelArguments() => {
    'dpi': dpi,
    'maxPages': maxPages,
    'maxPagePixels': maxPagePixels,
    'maxTotalBytes': maxTotalBytes,
    'jpegQuality': jpegQuality,
  };
}

/// Said once after a PDF import whose pages had to be rendered below the
/// chosen quality.
const pdfReducedResolutionMessage =
    'Pages were imported at reduced resolution to fit the document memory '
    'limit.';

/// The render density for a quality preset: High renders at 300 DPI, which
/// suits text recognition; the other presets use their own export density.
int pdfImportDpi(PdfQuality quality) => quality.targetDpi ?? 300;

/// Pixels whose decode and processing fit in [budgetBytes], mirroring
/// [estimateDecodedOpenCvBytes] plus about one encoded byte per pixel.
int _processablePixels(int budgetBytes) {
  if (budgetBytes <= 0) return 0;
  const decodeBytes = 4;
  const warpBytes = 16;
  const encodedBytes = 1;
  final full = budgetBytes ~/ (decodeBytes + warpBytes + encodedBytes);
  if (full <= maxWarpPixels) return full;
  // Above the warp cap, only the decode and encoded copies keep growing.
  return math.max(
    maxWarpPixels,
    (budgetBytes - maxWarpPixels * warpBytes) ~/ (decodeBytes + encodedBytes),
  );
}

/// Rendered pages of one PDF, as app-owned cache files.
class PdfImportBatch {
  const PdfImportBatch({
    this.paths = const [],
    this.pageCount = 0,
    this.rejected = 0,
    this.truncated = false,
    this.reduced = false,
    this.dpis = const [],
  });

  /// One JPEG per page, in order. The receiver deletes each one after reading
  /// it, and deletes any it does not read.
  final List<String> paths;

  /// Pages in the PDF.
  final int pageCount;

  /// Pages that could not be rendered within the per-image limits.
  final int rejected;

  /// Rendering stopped early at the page or document memory limit.
  final bool truncated;

  /// Some page was rendered below the chosen quality to fit the document's
  /// memory limit.
  final bool reduced;

  /// The density each of [paths] was rendered at, or null where the platform
  /// did not report one (the requested density applies then).
  final List<double?> dpis;

  /// The render density of the page at [paths] index [index].
  double sourceDpiAt(int index, PdfImportRequest request) =>
      (index < dpis.length ? dpis[index] : null) ?? request.dpi.toDouble();
}

enum PdfImportFailure {
  /// Password-protected, corrupt, or not a PDF.
  unreadable,

  /// The user cancelled while pages were rendering.
  cancelled,

  /// Anything else, including running out of memory.
  failed,
}

class PdfImportException implements Exception {
  const PdfImportException(this.failure);

  final PdfImportFailure failure;

  @override
  String toString() => 'PdfImportException(${failure.name})';
}

/// Picks a PDF with the system document picker and rasterizes its pages.
abstract interface class PdfPageImporter {
  /// Opens the picker. Returns false when the user cancelled it.
  Future<bool> pickDocument();

  /// Renders the picked document. Throws [PdfImportException].
  Future<PdfImportBatch> renderPages(
    PdfImportRequest request, {
    void Function(int completed, int total)? onProgress,
  });

  /// Asks a running [renderPages] to stop; it then throws
  /// [PdfImportFailure.cancelled] after deleting its files.
  Future<void> cancel();
}

/// Android implementation backed by MainActivity and PdfRenderer.
///
/// Keep the channel contract synchronized with
/// android/app/src/main/kotlin/com/fosscanner/app/PdfPageImport.kt and
/// MainActivity.kt. A dedicated channel keeps render progress separate from
/// OCR progress and share notifications.
class MethodChannelPdfPageImporter implements PdfPageImporter {
  MethodChannelPdfPageImporter._();

  static final instance = MethodChannelPdfPageImporter._();

  static const channel = MethodChannel('com.fosscanner.app/pdf_import');

  @override
  Future<bool> pickDocument() async =>
      await channel.invokeMethod<bool>('pickPdf') ?? false;

  @override
  Future<PdfImportBatch> renderPages(
    PdfImportRequest request, {
    void Function(int completed, int total)? onProgress,
  }) async {
    channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'pdfImportProgress' || onProgress == null) return;
      final arguments = call.arguments;
      if (arguments is! Map) return;
      final completed = arguments['completed'];
      final total = arguments['total'];
      if (completed is int && total is int && total > 0) {
        onProgress(completed.clamp(0, total), total);
      }
    });
    try {
      final reply = await channel.invokeMapMethod<String, Object?>(
        'renderPdf',
        request.toChannelArguments(),
      );
      return parsePdfImportBatch(reply);
    } on PlatformException catch (error) {
      throw PdfImportException(switch (error.code) {
        'pdf_unreadable' => PdfImportFailure.unreadable,
        'pdf_cancelled' => PdfImportFailure.cancelled,
        _ => PdfImportFailure.failed,
      });
    } finally {
      channel.setMethodCallHandler(null);
    }
  }

  @override
  Future<void> cancel() => channel.invokeMethod<void>('cancelPdfImport');
}

/// Defensive decoding of the platform reply; malformed entries are ignored.
PdfImportBatch parsePdfImportBatch(Map<String, Object?>? reply) {
  if (reply == null) return const PdfImportBatch();
  final paths = reply['paths'];
  final pageCount = reply['pageCount'];
  final rejected = reply['rejected'];
  final dpis = reply['dpis'];
  final validPaths = <String>[];
  final pathDpis = <double?>[];
  if (paths is List) {
    for (final (index, path) in paths.indexed) {
      if (path is! String || path.isEmpty) continue;
      validPaths.add(path);
      // Older platform code sends no densities; a malformed one is unknown.
      pathDpis.add(
        dpis is List && dpis.length == paths.length
            ? validSourceDpi(dpis[index])
            : null,
      );
    }
  }
  return PdfImportBatch(
    paths: validPaths,
    dpis: pathDpis,
    pageCount: pageCount is int && pageCount > 0 ? pageCount : 0,
    rejected: rejected is int && rejected > 0 ? rejected : 0,
    truncated: reply['truncated'] == true,
    reduced: reply['reduced'] == true,
  );
}
