import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;

/// Saves a finished PDF to a user-chosen location outside the app.
///
/// The location is chosen before the PDF is generated, so cancelling the
/// picker never wastes an export (OCR can take a while).
abstract interface class PdfDocumentSaver {
  /// Whether this platform offers a save action at all.
  bool get isSupported;

  /// Asks the user where to save a PDF suggested as [fileName].
  ///
  /// Returns null when the user cancelled the picker. Throws on failure.
  Future<PdfSaveTarget?> chooseTarget({required String fileName});
}

/// A location the user picked; exactly one of [write] or [discard] is called.
abstract interface class PdfSaveTarget {
  /// The file name the user chose, for confirmation messages.
  String get fileName;

  /// Renames the chosen document to [fileName] before [write], best effort.
  ///
  /// Returns the name the document now has, or null when it keeps
  /// [this.fileName] (the provider cannot rename documents, or the rename
  /// failed). Never throws.
  Future<String?> rename(String fileName);

  /// Copies [pdf] to the location. Throws on failure, leaving no partial
  /// document behind.
  Future<void> write(File pdf);

  /// Removes the empty document the picker created, best effort. Never
  /// throws.
  Future<void> discard();
}

/// Android's system document picker (ACTION_CREATE_DOCUMENT) via MainActivity.
///
/// The picker is part of the OS (also on ROMs without Google apps), needs no
/// storage permission, and lets the user rename the file. iOS is deliberately
/// unsupported: its share sheet already offers "Save to Files", and a native
/// exporter could not be built or verified alongside this change.
class PlatformPdfDocumentSaver implements PdfDocumentSaver {
  const PlatformPdfDocumentSaver();

  // MainActivity's existing channel (shared with OCR).
  static const _channel = MethodChannel('com.fosscanner.app/ocr');

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<PdfSaveTarget?> chooseTarget({required String fileName}) async {
    if (!isSupported) throw UnsupportedError('Saving requires Android');
    // Keep the contract in sync with MainActivity.handleChooseSaveTarget.
    final chosen = await _channel.invokeMethod<Object?>('chooseSaveTarget', {
      'fileName': fileName,
    });
    if (chosen == null) return null;
    final name = chosen is Map ? chosen['fileName'] : null;
    return _PlatformSaveTarget(
      name is String && name.trim().isNotEmpty ? name : fileName,
    );
  }
}

class _PlatformSaveTarget implements PdfSaveTarget {
  _PlatformSaveTarget(this.fileName);

  @override
  final String fileName;

  @override
  Future<String?> rename(String fileName) async {
    try {
      // Keep the contract in sync with MainActivity.handleRenameSaveTarget.
      final renamed = await PlatformPdfDocumentSaver._channel
          .invokeMethod<String>('renameSaveTarget', {'fileName': fileName});
      return renamed != null && renamed.trim().isNotEmpty ? renamed : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(File pdf) async {
    await PlatformPdfDocumentSaver._channel.invokeMethod<void>(
      'writeSaveTarget',
      {'sourcePath': pdf.path},
    );
  }

  @override
  Future<void> discard() async {
    try {
      await PlatformPdfDocumentSaver._channel.invokeMethod<void>(
        'discardSaveTarget',
      );
    } catch (_) {
      // Best effort: some providers cannot delete documents.
    }
  }
}
