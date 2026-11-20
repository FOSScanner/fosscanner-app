import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, OrdinalSortKey, SemanticsService;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/scanned_page.dart';
import '../services/document_memory.dart';
import '../services/draft_store.dart';
import '../services/image_metadata.dart';
import '../services/image_pdf_service.dart' as image_pdf;
import '../services/ocr_service.dart' as ocr_service;
import '../services/platform_capabilities.dart';
import '../widgets/transient_message.dart';
import 'barcode_scan_screen.dart';
import 'corner_adjust_screen.dart';
import 'page_preview_screen.dart';

const _thumbnailCacheWidth = 512;
const _sourceCodeUrl = 'https://github.com/FOSScanner/fosscanner-app';

class _DocumentCapacityException implements Exception {
  const _DocumentCapacityException();
}

enum _PhotoIntakeResult { added, skipped, capacityReached }

enum _CameraRecovery { retry, gallery }

/// Which exporter owns the running PDF generation, and therefore how a
/// cancellation has to reach it: the native renderer needs a channel message,
/// the Dart image-only exporter only polls the flag this screen already sets.
enum _PdfExporter { searchable, imageOnly }

typedef SourceImageSizeReader = Future<Size> Function(Uint8List imageBytes);

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({
    super.key,
    this.initialPages = const [],
    this.sharePlus,
    this.searchablePdfEnabled,
    this.draftStore = const NoOpDraftStore(),
    this.cornerAdjustOperations = const DefaultCornerAdjustOperations(),
    this.sourceImageSizeReader = readEncodedImageSize,
  });

  final List<ScannedPage> initialPages;
  final SharePlus? sharePlus;
  final bool? searchablePdfEnabled;
  final DraftStore draftStore;
  final CornerAdjustOperations cornerAdjustOperations;
  final SourceImageSizeReader sourceImageSizeReader;

  @override
  State<ScannerHomePage> createState() => _ScannerHomePageState();
}

class _ScannerHomePageState extends State<ScannerHomePage> {
  late final List<ScannedPage> _pages;
  late final SharePlus _sharePlus;
  final ImagePicker _picker = ImagePicker();
  final ImageProcessingQueue _imageProcessingQueue = ImageProcessingQueue();
  late final Future<void> _initialDraftRestore;
  Future<void> _draftWriteTail = Future<void>.value();
  List<ScannedPage>? _pendingDraftSnapshot;
  List<ScannedPage>? _activeDraftSnapshot;
  ScannedPage? _undoPage;
  bool _isDraftSaveScheduled = false;
  bool _draftSaveFailed = false;
  String? _deferredMessage;
  var _draftRevision = 0;
  var _documentGeneration = 0;
  var _undoGeneration = 0;
  final GlobalKey _shareButtonKey = GlobalKey();
  bool _useOcr = false;
  bool _isGeneratingPdf = false;
  bool _isSharingPdf = false;
  bool _isCancellingPdf = false;
  double? _pdfProgress;
  _PdfExporter? _pdfExporter;
  bool _isPickingImages = false;
  bool _isRestoringDraft = false;
  bool _draftRestoreFailed = false;
  bool _isClearingDraft = false;
  bool _isOpeningImageRoute = false;
  late bool _cameraSupported;

  @override
  void initState() {
    super.initState();
    _pages = [...widget.initialPages];
    _sharePlus = widget.sharePlus ?? SharePlus.instance;
    _cameraSupported = _picker.supportsImageSource(ImageSource.camera);
    _isRestoringDraft = _pages.isEmpty;
    _initialDraftRestore = _isRestoringDraft
        ? _restoreDraft()
        : Future<void>.value();
    _draftWriteTail = _initialDraftRestore;
    // Android can destroy MainActivity while the system picker/camera is in
    // front. image_picker stores that pending result for the restarted app,
    // but it is lost permanently unless retrieveLostData is called at startup.
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_recoverLostImages());
    }
  }

  Future<void> _restoreDraft() async {
    final revision = _draftRevision;
    try {
      final restored = await widget.draftStore.load();
      if (!mounted || revision != _draftRevision || _pages.isNotEmpty) return;
      if (restored.length > maxDocumentPages ||
          retainedPageImageBytes(restored) > maxRetainedDocumentBytes) {
        throw const _DocumentCapacityException();
      }
      setState(() {
        _pages.addAll(restored);
        _draftRestoreFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _draftRestoreFailed = true);
    } finally {
      if (mounted) setState(() => _isRestoringDraft = false);
    }
  }

  Future<void> _retryDraftRestore() async {
    if (_isRestoringDraft || _isClearingDraft || !_draftRestoreFailed) return;
    setState(() => _isRestoringDraft = true);
    await _restoreDraft();
    if (mounted &&
        !_draftRestoreFailed &&
        defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_recoverLostImages());
    }
  }

  Future<void> _discardFailedDraft() async {
    if (_isRestoringDraft || _isClearingDraft || !_draftRestoreFailed) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard saved draft?'),
        scrollable: true,
        content: const Text(
          'This permanently deletes the cached draft and its backup, including '
          'any pages that might still be recoverable. Exported PDFs are not removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard draft'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        _isRestoringDraft ||
        _isClearingDraft ||
        !_draftRestoreFailed) {
      return;
    }
    await _clearCurrentDraft();
    if (mounted &&
        !_draftRestoreFailed &&
        defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_recoverLostImages());
    }
  }

  Widget _buildDraftRestoreFailure() => Scaffold(
    appBar: AppBar(title: const Text('FOSScanner')),
    body: SafeArea(
      top: false,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  'Could not restore the saved draft',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your cached draft may still be recoverable. Adding images is '
                'paused to avoid replacing it. Check storage access and retry, '
                'or explicitly discard the draft to start again. '
                'Drafts are temporary app-cache data, not saved PDFs.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_isRestoringDraft || _isClearingDraft)
                const CircularProgressIndicator(
                  semanticsLabel: 'Opening draft',
                ),
              FilledButton(
                onPressed: _isRestoringDraft || _isClearingDraft
                    ? null
                    : _retryDraftRestore,
                child: const Text('Retry restoration'),
              ),
              TextButton(
                onPressed: _isRestoringDraft || _isClearingDraft
                    ? null
                    : _discardFailedDraft,
                child: const Text('Discard saved draft'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void _queueDraftSave() {
    if (_isClearingDraft || _isRestoringDraft || _draftRestoreFailed) return;
    _pendingDraftSnapshot = List<ScannedPage>.of(_pages);
    _draftRevision++;
    if (_isDraftSaveScheduled) return;
    _isDraftSaveScheduled = true;
    _draftWriteTail = _draftWriteTail.then((_) async {
      try {
        // Retain only the active write and the newest pending revision when
        // edits arrive faster than storage can commit a complete document.
        while (_pendingDraftSnapshot != null) {
          final snapshot = _pendingDraftSnapshot!;
          _pendingDraftSnapshot = null;
          _activeDraftSnapshot = snapshot;
          try {
            await widget.draftStore.save(snapshot);
            if (mounted) setState(() => _draftSaveFailed = false);
          } catch (_) {
            if (mounted) setState(() => _draftSaveFailed = true);
          } finally {
            _activeDraftSnapshot = null;
            if (mounted) setState(() {});
          }
        }
      } finally {
        _isDraftSaveScheduled = false;
        if (mounted) setState(() {});
      }
    });
  }

  Future<bool> _queueDraftClear() {
    _draftRevision++;
    final clearOperation = _draftWriteTail.then((_) async {
      try {
        await widget.draftStore.clear();
        return true;
      } catch (_) {
        if (mounted) _showMessage('Could not clear the saved draft.');
        return false;
      }
    });
    _draftWriteTail = clearOperation.then<void>((_) {});
    return clearOperation;
  }

  int _retainedImageBytesFor(Iterable<ScannedPage> pages) =>
      retainedPageImageBytes([
        ...pages,
        ...?_activeDraftSnapshot,
        ...?_pendingDraftSnapshot,
        ?_undoPage,
      ]);

  int get _retainedImageBytes => _retainedImageBytesFor(_pages);

  bool get _isDocumentInteractionLocked =>
      _draftRestoreFailed ||
      _isClearingDraft ||
      _isGeneratingPdf ||
      _isPickingImages ||
      _isOpeningImageRoute;

  bool get _canExport =>
      _pages.isNotEmpty && !_isRestoringDraft && !_isDocumentInteractionLocked;

  bool get _canStartImagePick =>
      !_draftRestoreFailed &&
      !_isRestoringDraft &&
      !_isClearingDraft &&
      !_isGeneratingPdf &&
      !_isOpeningImageRoute &&
      canRetainDocument(
        currentBytes: _retainedImageBytes,
        currentPages: _pages.length,
        incomingBytes: 1,
      );

  static const _documentMemoryLimitMessage =
      'There is not enough document memory for this image. '
      'Export a copy, then remove pages or choose a smaller image.';

  String get _documentLimitMessage => _pages.length >= maxDocumentPages
      ? 'This document has reached the $maxDocumentPages-page limit. '
            'Export it to keep a copy, then remove pages or clear the draft '
            'before adding more.'
      : _documentMemoryLimitMessage;

  String? get _imageIntakeStatus {
    if (_isRestoringDraft) {
      return 'Restoring your draft. Wait for restoration to finish before adding images.';
    }
    if (_isClearingDraft) {
      return 'Clearing your draft. Wait for clearing to finish before adding images.';
    }
    if (_isGeneratingPdf) {
      return 'Export is in progress. Finish or cancel the export before adding images.';
    }
    if (_isPickingImages || _isOpeningImageRoute) {
      return 'Image selection or page review is in progress. Finish or cancel it '
          'before adding more images.';
    }
    if (!_canStartImagePick) {
      if (_pages.length >= maxDocumentPages) return _documentLimitMessage;
      return '$_documentMemoryLimitMessage '
          'Memory held by Undo or a pending draft save is released when they finish.';
    }
    if (!_cameraSupported) {
      return 'Camera capture is unavailable on this device. '
          'Use Import from gallery to add images.';
    }
    return null;
  }

  void _showImageIntakeStatus() {
    final status = _imageIntakeStatus;
    if (status == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Adding images'),
        scrollable: true,
        content: Text(status),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showDocumentLimit() => _showMessage(_documentLimitMessage);

  void _showUnsupportedImageDimensions() {
    _showMessage(
      'This image is too small or has unsupported dimensions. '
      'Choose another image, or resize a large image and try again.',
    );
  }

  void _showImageProcessingMemoryLimit() {
    _showMessage(
      'This image needs too much temporary memory to process safely. '
      'Remove pages or choose a smaller image.',
    );
  }

  bool _tryAddPage(ScannedPage page, {required int documentGeneration}) {
    if (_isClearingDraft ||
        _isGeneratingPdf ||
        !mounted ||
        documentGeneration != _documentGeneration) {
      return false;
    }
    if (!canRetainDocument(
      currentBytes: _retainedImageBytesFor([..._pages, page]),
      currentPages: _pages.length,
      incomingBytes: 0,
    )) {
      _showDocumentLimit();
      return false;
    }
    setState(() => _pages.add(page));
    _queueDraftSave();
    return true;
  }

  void _showMessage(String message) {
    // Only the newest informational message survives until Undo expires or is
    // used. New deletions, export, and explicit clearing deliberately discard it.
    if (_undoPage != null) {
      _deferredMessage = message;
    } else {
      showTransientMessage(context, message);
    }
  }

  Future<void> _openSourceCode() async {
    try {
      final launched = await launchUrl(
        Uri.parse(_sourceCodeUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) _showMessage('Could not open the source code link.');
    } catch (_) {
      _showMessage('Could not open the source code link.');
    }
  }

  Future<void> _showAppInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;
    final theme = Theme.of(context);
    final mutedStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Image.asset('assets/icon/icon.png', width: 40, height: 40),
            const SizedBox(width: 12),
            const Expanded(child: Text('FOSScanner')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Version ${packageInfo.version} (build ${packageInfo.buildNumber})',
                style: mutedStyle,
              ),
              const SizedBox(height: 16),
              const Text(
                'A privacy-first, free and open-source document scanner. '
                'Scan documents with your camera, auto-crop and dewarp them, '
                'and export a PDF — all on-device. No accounts, no cloud, '
                'no tracking.',
              ),
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _openSourceCode,
                icon: const Icon(Icons.code),
                label: const Text('View source code'),
              ),
              const SizedBox(height: 4),
              Text('Licensed under the GNU GPL v3.0', style: mutedStyle),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _recoverLostImages() async {
    final documentGeneration = _documentGeneration;
    // Block a second picker request until startup recovery has completed; two
    // simultaneous results could otherwise push overlapping adjustment routes.
    _isPickingImages = true;
    try {
      // Restore the existing pages before admitting a recovered image so its
      // processing budget and next saved snapshot include the whole document.
      await _initialDraftRestore;
      if (!mounted || _draftRestoreFailed) return;
      final response = await _picker.retrieveLostData();
      if (!mounted || response.isEmpty) return;
      if (response.exception != null) {
        _showMessage('Could not recover the interrupted image selection.');
        return;
      }

      final files =
          response.files ?? [if (response.file != null) response.file!];
      for (var index = 0; index < files.length; index++) {
        if (!mounted) {
          for (final remaining in files.skip(index)) {
            await _deleteFileQuietly(remaining.path);
          }
          return;
        }
        // Android image_picker recovery paths are app-owned cache copies.
        final result = await _addCapturedPhoto(
          files[index],
          source: PageReviewSource.recovered,
          isBatchImport: files.length > 1,
          deleteAfterRead: true,
          documentGeneration: documentGeneration,
        );
        if (result == _PhotoIntakeResult.capacityReached) {
          for (final remaining in files.skip(index + 1)) {
            await _deleteFileQuietly(remaining.path);
          }
          break;
        }
      }
    } catch (_) {
      _showMessage('Could not recover the interrupted image selection.');
    } finally {
      if (mounted) setState(() => _isPickingImages = false);
    }
  }

  // Best-effort cleanup: the picker temp file is no longer needed once its
  // bytes are in app-managed memory (and, on native, queued for draft save).
  Future<void> _deleteFileQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Nothing actionable if cleanup fails; the OS will reclaim temp
      // storage eventually regardless.
    }
  }

  bool _isDefinitiveCameraUnavailable(Object error) =>
      error is PlatformException &&
      const {'camera-unavailable', 'no_available_camera'}.contains(error.code);

  Future<_CameraRecovery?> _showCameraFailure(Object error) {
    final code = error is PlatformException ? error.code : null;
    final unavailable = _isDefinitiveCameraUnavailable(error);
    final needsSettings =
        code == 'camera_access_denied' || code == 'camera_access_restricted';
    final message = switch (code) {
      'camera_access_denied' =>
        'Camera access was denied. Allow camera access for FOSScanner in '
            'your device settings before trying again. You can also import images.',
      'camera_access_restricted' =>
        'Camera access is restricted on this device. Check device restrictions '
            'with your device administrator. You can still import images.',
      _ when unavailable =>
        'No camera is available on this device. Import images instead.',
      _ => 'Could not open the camera. Try again or import images instead.',
    };
    return showDialog<_CameraRecovery>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Camera unavailable'),
        scrollable: true,
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _CameraRecovery.gallery),
            child: const Text('Import images'),
          ),
          if (!needsSettings && !unavailable)
            TextButton(
              onPressed: () => Navigator.pop(context, _CameraRecovery.retry),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  Future<void> _captureImage() async {
    if (_isRestoringDraft || _isDocumentInteractionLocked) {
      return;
    }
    if (!_canStartImagePick) {
      _showDocumentLimit();
      return;
    }
    final documentGeneration = _documentGeneration;
    _CameraRecovery? recovery;
    setState(() => _isPickingImages = true);
    try {
      await _imageProcessingQueue.idle;
      if (!mounted || documentGeneration != _documentGeneration) return;
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: maxPickerEdge,
        maxHeight: maxPickerEdge,
      );
      if (photo == null) return;
      // Camera capture writes a fresh file that's genuinely ours to delete.
      await _addCapturedPhoto(
        photo,
        source: PageReviewSource.camera,
        deleteAfterRead: true,
        documentGeneration: documentGeneration,
      );
    } catch (error) {
      if (!mounted) return;
      if (_isDefinitiveCameraUnavailable(error)) {
        setState(() => _cameraSupported = false);
      }
      recovery = await _showCameraFailure(error);
    } finally {
      if (mounted) setState(() => _isPickingImages = false);
    }
    if (!mounted || documentGeneration != _documentGeneration) return;
    switch (recovery) {
      case _CameraRecovery.retry:
        await _captureImage();
      case _CameraRecovery.gallery:
        await _importFromGallery();
      case null:
        break;
    }
  }

  Future<void> _importFromGallery() async {
    if (_isRestoringDraft || _isDocumentInteractionLocked) {
      return;
    }
    if (!_canStartImagePick) {
      _showDocumentLimit();
      return;
    }
    final documentGeneration = _documentGeneration;
    setState(() => _isPickingImages = true);
    try {
      await _imageProcessingQueue.idle;
      if (!mounted || documentGeneration != _documentGeneration) return;
      final List<XFile> photos = await _picker.pickMultiImage(
        maxWidth: maxPickerEdge,
        maxHeight: maxPickerEdge,
        limit: maxDocumentPages - _pages.length,
      );
      for (final photo in photos) {
        if (_isClearingDraft) break;
        if (!_canStartImagePick) {
          _showDocumentLimit();
          break;
        }
        // Unlike camera capture, a gallery pick's path isn't reliably an
        // app-owned temp copy across platforms — don't risk deleting a file
        // that might actually be the user's original photo.
        final result = await _addCapturedPhoto(
          photo,
          source: PageReviewSource.gallery,
          isBatchImport: photos.length > 1,
          deleteAfterRead: false,
          documentGeneration: documentGeneration,
        );
        if (result == _PhotoIntakeResult.capacityReached) break;
      }
    } catch (_) {
      _showMessage('Could not open the photo gallery.');
    } finally {
      if (mounted) setState(() => _isPickingImages = false);
    }
  }

  CornerAdjustScreen _buildEditor(
    Uint8List originalBytes, {
    ScannedPage? page,
    PageReviewSource? source,
    bool isBatchImport = false,
  }) {
    return CornerAdjustScreen(
      originalBytes: originalBytes,
      source: source,
      isBatchImport: isBatchImport,
      initialCorners: page?.corners,
      startWithAdjustments: page != null,
      initialFilter: page?.filter ?? PageFilter.original,
      initialRotationQuarterTurns: page?.rotationQuarterTurns ?? 0,
      initialBrightness: page?.brightness ?? 0,
      initialContrast: page?.contrast ?? 1,
      operations: widget.cornerAdjustOperations,
      processingQueue: _imageProcessingQueue,
    );
  }

  /// Shared by camera capture and gallery import: read the file's bytes,
  /// optionally delete the source file, then (native only) run the photo
  /// through the detect/adjust flow before adding it as a page.
  Future<_PhotoIntakeResult> _addCapturedPhoto(
    XFile photo, {
    required PageReviewSource source,
    bool isBatchImport = false,
    required bool deleteAfterRead,
    required int documentGeneration,
  }) async {
    if (_isClearingDraft || documentGeneration != _documentGeneration) {
      if (deleteAfterRead) await _deleteFileQuietly(photo.path);
      return _PhotoIntakeResult.skipped;
    }

    late final Uint8List bytes;
    try {
      try {
        final declaredLength = await photo.length();
        if (declaredLength > maxEncodedImageBytes) {
          throw EncodedImageTooLargeError(maxEncodedImageBytes);
        }
        final readLimit = availableEncodedImageBytes(
          currentBytes: _retainedImageBytes,
        );
        if (readLimit == 0 || declaredLength > readLimit) {
          throw const _DocumentCapacityException();
        }
        // Enforce the residual document limit while streaming too: the source
        // can change after length(), and some XFile implementations cannot
        // provide a stable filesystem length.
        try {
          bytes = await readBoundedBytes(
            photo.openRead(0, declaredLength),
            maxBytes: readLimit,
          );
        } on EncodedImageTooLargeError {
          if (readLimit < maxEncodedImageBytes) {
            throw const _DocumentCapacityException();
          }
          rethrow;
        }
      } finally {
        if (deleteAfterRead) {
          await _deleteFileQuietly(photo.path);
        }
      }
    } on _DocumentCapacityException {
      _showDocumentLimit();
      return _PhotoIntakeResult.capacityReached;
    } on EncodedImageTooLargeError {
      _showMessage(
        'This image file is too large to process safely. Choose a file under '
        '${maxEncodedImageBytes ~/ (1024 * 1024)} MB.',
      );
      return _PhotoIntakeResult.skipped;
    } catch (_) {
      _showMessage('Could not read this photo.');
      return _PhotoIntakeResult.skipped;
    }

    if (_isClearingDraft || documentGeneration != _documentGeneration) {
      return _PhotoIntakeResult.skipped;
    }
    if (!canRetainDocument(
      currentBytes: _retainedImageBytes,
      currentPages: _pages.length,
      incomingBytes: bytes.length,
    )) {
      _showDocumentLimit();
      return _PhotoIntakeResult.capacityReached;
    }

    late final Size imageSize;
    try {
      imageSize = await readEncodedImageSize(bytes);
      validateSourceImageSize(imageSize);
    } on UnsupportedError {
      _showUnsupportedImageDimensions();
      return _PhotoIntakeResult.skipped;
    } catch (_) {
      _showMessage('Could not read this photo.');
      return _PhotoIntakeResult.skipped;
    }
    if (!mounted ||
        _isClearingDraft ||
        documentGeneration != _documentGeneration) {
      return _PhotoIntakeResult.skipped;
    }

    if (!canProcessSourceImage(
      currentRetainedBytes: _retainedImageBytes,
      encodedBytes: bytes.length,
      size: imageSize,
    )) {
      _showImageProcessingMemoryLimit();
      return _PhotoIntakeResult.skipped;
    }

    final result = await Navigator.of(context).push<ScannedPage>(
      MaterialPageRoute(
        builder: (_) =>
            _buildEditor(bytes, source: source, isBatchImport: isBatchImport),
      ),
    );
    if (result == null ||
        !mounted ||
        _isClearingDraft ||
        documentGeneration != _documentGeneration) {
      return _PhotoIntakeResult.skipped;
    }
    return _tryAddPage(result, documentGeneration: documentGeneration)
        ? _PhotoIntakeResult.added
        : _PhotoIntakeResult.capacityReached;
  }

  Future<void> _openBarcodeScanner() async {
    if (_isRestoringDraft || _isDocumentInteractionLocked) {
      return;
    }
    setState(() => _isOpeningImageRoute = true);
    try {
      await _imageProcessingQueue.idle;
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const BarcodeScanScreen()),
      );
    } finally {
      if (mounted) setState(() => _isOpeningImageRoute = false);
    }
  }

  Future<void> _openPage(int index) async {
    if (_isDocumentInteractionLocked || index < 0 || index >= _pages.length) {
      return;
    }

    // Acquire this home page's editor lock before opening the preview.
    // This blocks stale, rapid card taps from starting overlapping routes.
    setState(() => _isOpeningImageRoute = true);
    try {
      final page = _pages[index];
      final documentGeneration = _documentGeneration;
      bool requestIsCurrent() =>
          mounted &&
          !_isClearingDraft &&
          documentGeneration == _documentGeneration &&
          index < _pages.length &&
          identical(_pages[index], page);

      final editRequested = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PagePreviewScreen(
            imageBytes: page.processedBytes,
            pageNumber: index + 1,
          ),
        ),
      );
      if (editRequested != true || !requestIsCurrent()) return;
      await _imageProcessingQueue.idle;
      if (!requestIsCurrent()) return;

      late final Size imageSize;
      try {
        imageSize = await widget.sourceImageSizeReader(page.originalBytes);
        validateSourceImageSize(imageSize);
      } on UnsupportedError {
        if (!requestIsCurrent()) return;
        _showUnsupportedImageDimensions();
        return;
      } catch (_) {
        if (requestIsCurrent()) _showMessage('Could not read this photo.');
        return;
      }
      if (!requestIsCurrent()) return;
      if (!canProcessSourceImage(
        currentRetainedBytes: _retainedImageBytes,
        // The source is already part of the retained document total.
        encodedBytes: 0,
        size: imageSize,
      )) {
        _showImageProcessingMemoryLimit();
        return;
      }

      if (!mounted) return;
      final result = await Navigator.of(context).push<ScannedPage>(
        MaterialPageRoute(
          builder: (_) => _buildEditor(page.originalBytes, page: page),
        ),
      );
      if (result != null && requestIsCurrent()) {
        final replacementPages = List<ScannedPage>.of(_pages)..removeAt(index);
        final retainedWithoutPage = _retainedImageBytesFor(replacementPages);
        replacementPages.insert(index, result);
        // An active draft write may still own the old processed image. Only
        // subtract storage that actually loses its last tracked owner.
        final currentBytes = _retainedImageBytes;
        if (!canReplaceDocumentPage(
          currentBytes: currentBytes,
          currentPages: _pages.length,
          replacedBytes: currentBytes - retainedWithoutPage,
          replacementBytes:
              _retainedImageBytesFor(replacementPages) - retainedWithoutPage,
        )) {
          _showMessage(_documentMemoryLimitMessage);
          return;
        }
        setState(() => _pages[index] = result);
        _queueDraftSave();
      }
    } finally {
      if (mounted) {
        setState(() => _isOpeningImageRoute = false);
      } else {
        _isOpeningImageRoute = false;
      }
    }
  }

  void _removePage(int index) {
    if (_isDocumentInteractionLocked || index < 0 || index >= _pages.length) {
      return;
    }
    _deferredMessage = null;
    _undoPage = _pages[index];
    final undoGeneration = ++_undoGeneration;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    setState(() => _pages.removeAt(index));
    _queueDraftSave();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: const Text('Page deleted.'),
        // Flutter otherwise makes action snackbars persistent by default.
        // Explicitly opt into expiry even though Undo provides an action.
        persist: false,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted ||
                _isDocumentInteractionLocked ||
                undoGeneration != _undoGeneration) {
              return;
            }
            final removed = _undoPage;
            if (removed == null) return;
            if (!canRetainDocument(
              currentBytes: _retainedImageBytes,
              currentPages: _pages.length,
              incomingBytes: 0,
            )) {
              _showDocumentLimit();
              return;
            }
            final restoredIndex = index > _pages.length ? _pages.length : index;
            setState(() {
              _pages.insert(restoredIndex, removed);
              _undoPage = null;
            });
            _queueDraftSave();
          },
        ),
      ),
    );
    unawaited(
      controller.closed.then((_) {
        if (!mounted || undoGeneration != _undoGeneration) return;
        setState(() => _undoPage = null);
        final message = _deferredMessage;
        _deferredMessage = null;
        if (message != null) _showMessage(message);
      }),
    );
  }

  Widget _pageReorderMenu(int index, ScannedPage page) => PopupMenuButton<int>(
    tooltip: 'Reorder page ${index + 1}',
    icon: const Icon(Icons.swap_vert),
    enabled: !_isDocumentInteractionLocked,
    onSelected: (direction) {
      // A menu callback must not move a different page if the document changed
      // while it was open. _reorderPage also rechecks the operation lock.
      if (index >= _pages.length || !identical(_pages[index], page)) return;
      _reorderPage(index, index + direction);
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        value: -1,
        enabled: index > 0,
        child: const ListTile(
          leading: Icon(Icons.arrow_upward),
          title: Text('Move earlier'),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      PopupMenuItem(
        value: 1,
        enabled: index < _pages.length - 1,
        child: const ListTile(
          leading: Icon(Icons.arrow_downward),
          title: Text('Move later'),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ],
  );

  void _reorderPage(int fromIndex, int toIndex) {
    if (_isDocumentInteractionLocked ||
        fromIndex < 0 ||
        fromIndex >= _pages.length ||
        toIndex < 0 ||
        toIndex >= _pages.length ||
        fromIndex == toIndex) {
      return;
    }
    setState(() {
      final page = _pages.removeAt(fromIndex);
      _pages.insert(toIndex, page);
    });
    _queueDraftSave();
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Page moved to position ${toIndex + 1} of ${_pages.length}.',
      Directionality.of(context),
    );
  }

  Future<void> _clearPages() async {
    if (_isClearingDraft || _isGeneratingPdf) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all pages?'),
        content: const Text(
          'This removes every page from the current draft. '
          'Drafts are temporary app-cache data, not saved PDFs. '
          'PDFs already shared are not removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _isClearingDraft || _isGeneratingPdf) {
      return;
    }
    await _clearCurrentDraft();
  }

  Future<void> _clearCurrentDraft() async {
    if (_isClearingDraft || _isGeneratingPdf) return;
    _documentGeneration++;
    setState(() => _isClearingDraft = true);

    var cleared = false;
    try {
      cleared = await _queueDraftClear();
    } catch (_) {
      if (mounted) _showMessage('Could not clear the saved draft.');
    }
    if (!mounted) return;

    if (cleared) {
      _undoPage = null;
      _undoGeneration++;
      ScaffoldMessenger.of(context).clearSnackBars();
    }
    setState(() {
      if (cleared) {
        _pages.clear();
        _draftRestoreFailed = false;
        _draftSaveFailed = false;
        _deferredMessage = null;
      }
      _isClearingDraft = false;
    });
  }

  bool get _ocrSupported =>
      widget.searchablePdfEnabled ??
      defaultTargetPlatform == TargetPlatform.android;

  void _updatePdfProgress(int completed, int total) {
    if (mounted) setState(() => _pdfProgress = completed / total);
  }

  Future<Uint8List> _createSearchablePdf(List<ScannedPage> pages) {
    return ocr_service.createSearchablePdf([
      for (final page in pages) page.processedBytes,
    ], onProgress: _updatePdfProgress);
  }

  Future<bool> _confirmImageOnlyFallback() async {
    if (!mounted) return false;
    final fallback = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Searchable export failed'),
        content: const Text(
          'OCR could not create a searchable PDF for this document. '
          'Share an image-only PDF instead?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Share image-only PDF'),
          ),
        ],
      ),
    );
    return fallback ?? false;
  }

  Future<ShareResult> _sharePdfBytes(
    Uint8List pdfBytes, {
    required String fileName,
    required String message,
    required Rect? shareOrigin,
  }) {
    return _sharePlus.share(
      ShareParams(
        files: [
          XFile.fromData(pdfBytes, name: fileName, mimeType: 'application/pdf'),
        ],
        fileNameOverrides: [fileName],
        text: message,
        sharePositionOrigin: shareOrigin,
        downloadFallbackEnabled: true,
      ),
    );
  }

  Future<Uint8List> _createImageOnlyPdf(List<ScannedPage> pages) {
    return image_pdf.createImageOnlyPdf(
      [for (final page in pages) page.processedBytes],
      onProgress: _updatePdfProgress,
      isCancelled: () => _isCancellingPdf,
    );
  }

  Rect? get _shareOrigin {
    final box =
        _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _cancelPdfGeneration() async {
    if (!_isGeneratingPdf || _isCancellingPdf || _pdfProgress == null) return;
    setState(() => _isCancellingPdf = true);
    // The image-only exporter polls the flag set above between pages; only the
    // native renderer has to be told over the channel.
    if (_pdfExporter != _PdfExporter.searchable) return;
    try {
      await ocr_service.cancelSearchablePdf();
    } catch (error) {
      if (mounted && !ocr_service.isCancellation(error)) {
        _showMessage('Could not cancel PDF generation.');
      }
    }
  }

  Future<({Uint8List bytes, bool searchable})?> _createPdf(
    List<ScannedPage> pages, {
    required bool useOcr,
  }) async {
    if (useOcr) {
      try {
        return (bytes: await _createSearchablePdf(pages), searchable: true);
      } catch (error) {
        if (ocr_service.isCancellation(error)) rethrow;
        if (!mounted) return null;
        setState(() => _pdfProgress = null);
        if (!await _confirmImageOnlyFallback()) return null;
      }
    }

    if (!mounted) return null;
    setState(() {
      // A confirmed fallback starts fresh after an OCR failure.
      _isCancellingPdf = false;
      _pdfExporter = _PdfExporter.imageOnly;
      _pdfProgress = 0;
    });
    return (bytes: await _createImageOnlyPdf(pages), searchable: false);
  }

  Future<void> _generateAndSharePdf() async {
    if (!_canExport) return;
    // Drop Undo before exporting so a deleted page cannot consume untracked
    // headroom or be restored by a callback captured before the export lock.
    _undoGeneration++;
    _undoPage = null;
    _deferredMessage = null;
    ScaffoldMessenger.of(context).clearSnackBars();
    final pages = List<ScannedPage>.of(_pages, growable: false);
    final useOcr = _ocrSupported && _useOcr;
    // Capture the required iPad popover anchor before awaiting worker results.
    final shareOrigin = _shareOrigin;

    setState(() {
      _isGeneratingPdf = true;
      _isSharingPdf = false;
      _isCancellingPdf = false;
      _pdfExporter = useOcr ? _PdfExporter.searchable : _PdfExporter.imageOnly;
      _pdfProgress = 0;
    });

    try {
      // Popping an editor does not interrupt its active worker. Use the same
      // queue so PDF/OCR processing cannot overlap that native allocation.
      final pdf = await _imageProcessingQueue.run(() async {
        if (!mounted) return null;
        if (_isCancellingPdf) {
          throw const image_pdf.ImagePdfCancelledException();
        }
        return _createPdf(pages, useOcr: useOcr);
      });
      if (pdf == null || !mounted || _isCancellingPdf) return;
      setState(() {
        _pdfProgress = null;
        _isSharingPdf = true;
      });
      final prefix = pdf.searchable ? 'FOSScanner_searchable' : 'FOSScanner';
      await _sharePdfBytes(
        pdf.bytes,
        fileName: '${prefix}_${DateTime.now().millisecondsSinceEpoch}.pdf',
        message: pdf.searchable
            ? 'Searchable document scanned with FOSScanner'
            : 'Document scanned with FOSScanner',
        shareOrigin: shareOrigin,
      );
    } catch (error) {
      if (ocr_service.isCancellation(error) ||
          error is image_pdf.ImagePdfCancelledException) {
        if (mounted) _showMessage('PDF generation cancelled.');
      } else {
        if (kDebugMode) {
          debugPrint('PDF generation failed (${error.runtimeType}).');
        }
        if (mounted) _showMessage('Could not generate or share the PDF.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPdf = false;
          _isSharingPdf = false;
          _isCancellingPdf = false;
          _pdfExporter = null;
          _pdfProgress = null;
        });
      }
    }
  }

  Future<void> _showExportOptions() async {
    if (!_canExport || !_ocrSupported) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'PDF export options',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Searchable text'),
                  subtitle: Text(
                    _useOcr
                        ? 'Recognize text so you can search and select it in the PDF.'
                        : 'Image-only PDF without text recognition.',
                  ),
                  value: _useOcr,
                  onChanged: (value) {
                    if (!mounted || !_canExport || !sheetContext.mounted) {
                      return;
                    }
                    setState(() => _useOcr = value);
                    updateSheet(() {});
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  'Text recognition supports Latin-script text and runs '
                  'entirely on your device. Your scans stay private.',
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _exportStatus {
    if (_isClearingDraft) return 'Clearing draft...';
    if (_isCancellingPdf) return 'Cancelling PDF...';
    if (_isSharingPdf) return 'Opening share sheet...';
    if (_pdfProgress == null) return 'Preparing PDF...';
    return 'Generating PDF ${(_pdfProgress! * 100).round()}%';
  }

  Widget _buildExportBar() {
    final busy = _isGeneratingPdf || _isClearingDraft;
    return SafeArea(
      key: const Key('pdf_export_bar'),
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth < 300 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21;
              final progress = Row(
                children: [
                  SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      value: _isCancellingPdf ? null : _pdfProgress,
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(_exportStatus),
                    ),
                  ),
                ],
              );
              final cancel = _isGeneratingPdf && _pdfProgress != null
                  ? TextButton(
                      onPressed: _isCancellingPdf ? null : _cancelPdfGeneration,
                      child: const Text('Cancel'),
                    )
                  : null;
              if (busy) {
                return stacked
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [progress, ?cancel],
                      )
                    : Row(
                        children: [
                          Expanded(child: progress),
                          ?cancel,
                        ],
                      );
              }
              final exportButton = FilledButton.icon(
                key: _shareButtonKey,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 16,
                  ),
                ),
                onPressed: _canExport ? _generateAndSharePdf : null,
                icon: const Icon(Icons.picture_as_pdf),
                label: Text(
                  'Export PDF (${_pages.length} '
                  '${_pages.length == 1 ? 'page' : 'pages'})',
                  textAlign: TextAlign.center,
                ),
              );
              final options = _ocrSupported
                  ? Semantics(
                      value: _useOcr
                          ? 'Searchable text enabled'
                          : 'Image-only PDF',
                      child: IconButton.filledTonal(
                        onPressed: _canExport ? _showExportOptions : null,
                        tooltip: 'PDF export options',
                        icon: const Icon(Icons.tune),
                      ),
                    )
                  : null;
              if (stacked) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    exportButton,
                    if (options != null)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: options,
                      ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: exportButton),
                  if (options != null) ...[const SizedBox(width: 8), options],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  SliverGridDelegate _pageGridDelegate(BuildContext context, double width) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    // Keep ordinary phone cards compact, but give large text a full-width
    // card instead of squeezing its label and two 48px actions into a footer.
    final minCardWidth = 168 + 52 * (textScale - 1).clamp(0.0, 1.0);
    final columns = ((width - 8) / (minCardWidth + 8)).floor().clamp(1, 6);
    final cardWidth = (width - 16 - 8 * (columns - 1)) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      mainAxisExtent: cardWidth * 1.3 + 48 + 36 * textScale,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_draftRestoreFailed) return _buildDraftRestoreFailure();
    final compactActions =
        MediaQuery.sizeOf(context).width -
                MediaQuery.paddingOf(context).horizontal <
            380 ||
        MediaQuery.textScalerOf(context).scale(20) > 28;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FOSScanner'),
        actions: [
          if (!compactActions &&
              supportsBarcodeCamera(
                platform: defaultTargetPlatform,
                isWeb: kIsWeb,
              ))
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: _isRestoringDraft || _isDocumentInteractionLocked
                  ? null
                  : _openBarcodeScanner,
              tooltip: 'Scan QR/barcode',
            ),
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            onPressed:
                _isPickingImages || _isClearingDraft || !_canStartImagePick
                ? null
                : _importFromGallery,
            tooltip: 'Import from gallery',
          ),
          if (!compactActions && _pages.isNotEmpty)
            IconButton(
              icon: _isClearingDraft
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.clear_all),
              onPressed: _isClearingDraft || _isGeneratingPdf
                  ? null
                  : _clearPages,
              tooltip: 'Clear all',
            ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            onSelected: (action) {
              switch (action) {
                case 'barcode':
                  _openBarcodeScanner();
                case 'clear':
                  _clearPages();
                case 'about':
                  _showAppInfo();
              }
            },
            itemBuilder: (_) => [
              if (compactActions &&
                  supportsBarcodeCamera(
                    platform: defaultTargetPlatform,
                    isWeb: kIsWeb,
                  ))
                PopupMenuItem(
                  value: 'barcode',
                  enabled: !_isRestoringDraft && !_isDocumentInteractionLocked,
                  child: const Text('Scan QR/barcode'),
                ),
              if (compactActions && _pages.isNotEmpty)
                PopupMenuItem(
                  value: 'clear',
                  enabled: !_isClearingDraft && !_isGeneratingPdf,
                  child: const Text('Clear all'),
                ),
              const PopupMenuItem(
                value: 'about',
                child: Text('About FOSScanner'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              if (_imageIntakeStatus != null || _pages.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * 0.4,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_imageIntakeStatus != null)
                          TextButton.icon(
                            onPressed: _showImageIntakeStatus,
                            icon: const Icon(Icons.info_outline),
                            label: const Text('Image intake help'),
                          ),
                        if (_pages.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: Text(
                              'Drafts are temporary. Export a PDF to keep a copy.',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (_draftSaveFailed)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * 0.6,
                  ),
                  child: SingleChildScrollView(
                    child: MaterialBanner(
                      content: Semantics(
                        liveRegion: true,
                        child: Text(
                          'Could not save the latest draft changes. '
                          'Keep the app open and retry. Drafts are temporary '
                          'app-cache data, not saved PDFs.',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: _isDraftSaveScheduled || _isClearingDraft
                              ? null
                              : _queueDraftSave,
                          child: const Text('Retry saving draft'),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: _pages.isEmpty
                    ? Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(32.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_isRestoringDraft)
                                const CircularProgressIndicator()
                              else
                                Icon(
                                  _cameraSupported
                                      ? Icons.camera_alt
                                      : Icons.photo_library_outlined,
                                  size: 80,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              const SizedBox(height: 16),
                              Text(
                                _isRestoringDraft
                                    ? 'Restoring draft...'
                                    : 'Ready to Scan',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _isRestoringDraft
                                    ? 'Your saved pages will appear here.'
                                    : _cameraSupported
                                    ? 'Tap the camera button to add your first document. FOSS & Privacy-first: everything is processed on your device.'
                                    : 'Import from your gallery to add your first document. FOSS & Privacy-first: everything is processed on your device.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: EdgeInsets.fromLTRB(
                          8,
                          8,
                          8,
                          _cameraSupported ? 96 : 8,
                        ),
                        gridDelegate: _pageGridDelegate(
                          context,
                          constraints.maxWidth,
                        ),
                        itemCount: _pages.length,
                        itemBuilder: (context, index) {
                          final page = _pages[index];
                          final card = Card(
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: _isDocumentInteractionLocked
                                  ? null
                                  : () => _openPage(index),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        8,
                                        8,
                                        0,
                                      ),
                                      child: Image(
                                        image: ResizeImage(
                                          MemoryImage(page.processedBytes),
                                          width: _thumbnailCacheWidth,
                                          height: _thumbnailCacheWidth,
                                          policy: ResizeImagePolicy.fit,
                                        ),
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 12,
                                      right: 4,
                                    ),
                                    child: Wrap(
                                      alignment: WrapAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        ExcludeSemantics(
                                          child: Text(
                                            'Page ${index + 1}',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelLarge,
                                          ),
                                        ),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_pages.length > 1)
                                              _pageReorderMenu(index, page),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete_outline,
                                              ),
                                              tooltip:
                                                  'Delete page ${index + 1}',
                                              onPressed:
                                                  _isDocumentInteractionLocked
                                                  ? null
                                                  : () => _removePage(index),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );

                          // Drag-to-reorder remains available alongside equivalent
                          // semantic actions for switch and screen-reader users.
                          final reorderActions =
                              <CustomSemanticsAction, VoidCallback>{
                                if (!_isDocumentInteractionLocked && index > 0)
                                  const CustomSemanticsAction(
                                    label: 'Move earlier',
                                  ): () =>
                                      _reorderPage(index, index - 1),
                                if (!_isDocumentInteractionLocked &&
                                    index < _pages.length - 1)
                                  const CustomSemanticsAction(
                                    label: 'Move later',
                                  ): () =>
                                      _reorderPage(index, index + 1),
                              };
                          return Semantics(
                            key: ValueKey('page_semantics_$index'),
                            label: 'Page ${index + 1} of ${_pages.length}',
                            sortKey: OrdinalSortKey(index.toDouble()),
                            container: true,
                            customSemanticsActions: reorderActions,
                            child: DragTarget<int>(
                              onWillAcceptWithDetails: (details) =>
                                  !_isDocumentInteractionLocked &&
                                  details.data != index,
                              onAcceptWithDetails: (details) =>
                                  _reorderPage(details.data, index),
                              builder: (context, candidateData, rejectedData) {
                                final isDropTarget = candidateData.isNotEmpty;
                                return LongPressDraggable<int>(
                                  data: index,
                                  maxSimultaneousDrags:
                                      _isDocumentInteractionLocked ? 0 : 1,
                                  feedback: SizedBox(
                                    width: 140,
                                    height: 200,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: Opacity(
                                        opacity: 0.85,
                                        child: card,
                                      ),
                                    ),
                                  ),
                                  childWhenDragging: Opacity(
                                    opacity: 0.3,
                                    child: card,
                                  ),
                                  child: isDropTarget
                                      ? Container(
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              width: 3,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: card,
                                        )
                                      : card,
                                );
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _cameraSupported
          ? FloatingActionButton(
              onPressed:
                  _isPickingImages || _isClearingDraft || !_canStartImagePick
                  ? null
                  : _captureImage,
              tooltip: 'Capture Image',
              child: const Icon(Icons.camera_alt),
            )
          : null,
      bottomNavigationBar: _pages.isEmpty ? null : _buildExportBar(),
    );
  }
}
