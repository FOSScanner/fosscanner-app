import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;

/// Saves a finished PDF to a user-chosen location outside the app.
abstract interface class PdfDocumentSaver {
  /// Whether this platform offers a save action at all.
  bool get isSupported;

  /// Asks the user where to save [pdf] as [fileName] and copies it there.
  ///
  /// Returns false when the user cancelled the picker. Throws on failure.
  Future<bool> save(File pdf, {required String fileName});
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
  Future<bool> save(File pdf, {required String fileName}) async {
    if (!isSupported) throw UnsupportedError('Saving requires Android');
    // Keep the contract in sync with MainActivity.handleSavePdfDocument.
    final saved = await _channel.invokeMethod<bool>('savePdfDocument', {
      'sourcePath': pdf.path,
      'fileName': fileName,
    });
    return saved ?? false;
  }
}
