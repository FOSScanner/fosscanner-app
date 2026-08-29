import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/scanned_page.dart';
import '../services/draft_store.dart';
import '../services/image_metadata.dart';
import '../widgets/transient_message.dart';
import 'barcode_scan_screen.dart';
import 'corner_adjust_screen.dart';

const _thumbnailCacheWidth = 512;
const _sourceCodeUrl = 'https://github.com/FOSScanner/fosscanner-app';

class _DocumentCapacityException implements Exception {
  const _DocumentCapacityException();
}

enum _PhotoIntakeResult { added, skipped, capacityReached }

typedef SourceImageSizeReader = Future<Size> Function(Uint8List imageBytes);

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({
    super.key,
    this.initialPages = const [],
    this.sharePlus,
    this.draftStore = const NoOpDraftStore(),
    this.cornerAdjustOperations = const DefaultCornerAdjustOperations(),
    this.sourceImageSizeReader = readEncodedImageSize,
  });

  final List<ScannedPage> initialPages;
  final SharePlus? sharePlus;
  final DraftStore draftStore;
  final CornerAdjustOperations cornerAdjustOperations;
  final SourceImageSizeReader sourceImageSizeReader;

  @override
  State<ScannerHomePage> createState() => _ScannerHomePageState();
}

// Assumed resolution (dots per inch) of a warped page's pixel dimensions,
// used only to turn pixels into a printable-sized PDF page. It doesn't
// need to be exact — it just keeps pages roughly letter/A4-scale instead
// of pixel-count-as-points producing an absurdly large physical page.
const _scanDpi = 150.0;

class _ScannerHomePageState extends State<ScannerHomePage> {
  late final List<ScannedPage> _pages;
  late final SharePlus _sharePlus;
  final ImagePicker _picker = ImagePicker();
  final ImageProcessingQueue _imageProcessingQueue = ImageProcessingQueue();
  Future<void> _draftWriteTail = Future<void>.value();
  var _draftRevision = 0;
  var _documentGeneration = 0;
  var _undoGeneration = 0;
  final GlobalKey _shareButtonKey = GlobalKey();
  bool _isGeneratingPdf = false;
  bool _isPickingImages = false;
  bool _isClearingDraft = false;
  bool _isOpeningEditor = false;
  late bool _cameraSupported;

  @override
  void initState() {
    super.initState();
    _pages = [...widget.initialPages];
    _sharePlus = widget.sharePlus ?? SharePlus.instance;
    _cameraSupported = _picker.supportsImageSource(ImageSource.camera);
    if (_pages.isEmpty) _draftWriteTail = _restoreDraft();
    // Android can destroy MainActivity while the system picker/camera is in
    // front. image_picker stores that pending result for the restarted app,
    // but it is lost permanently unless retrieveLostData is called at startup.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_recoverLostImages());
    }
  }

  Future<void> _restoreDraft() async {
    final revision = _draftRevision;
    try {
      final restored = await widget.draftStore.load();
      if (!mounted || revision != _draftRevision || _pages.isNotEmpty) return;
      var retainedBytes = 0;
      for (var index = 0; index < restored.length; index++) {
        final pageBytes = _pageMemoryBytes(restored[index]);
        if (!canRetainDocument(
          currentBytes: retainedBytes,
          currentPages: index,
          incomingBytes: pageBytes,
        )) {
          throw const _DocumentCapacityException();
        }
        retainedBytes += pageBytes;
      }
      if (restored.isNotEmpty) setState(() => _pages.addAll(restored));
    } catch (_) {
      if (mounted) _showMessage('Could not restore the saved draft.');
    }
  }

  void _queueDraftSave() {
    if (_isClearingDraft) return;
    final snapshot = List<ScannedPage>.of(_pages);
    _draftRevision++;
    _draftWriteTail = _draftWriteTail.then((_) async {
      try {
        await widget.draftStore.save(snapshot);
      } catch (_) {
        if (mounted) _showMessage('Could not save the draft.');
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

  int _pageMemoryBytes(ScannedPage page) =>
      page.originalBytes.length +
      (identical(page.originalBytes, page.processedBytes)
          ? 0
          : page.processedBytes.length);

  int get _retainedDocumentBytes =>
      _pages.fold(0, (total, page) => total + _pageMemoryBytes(page));

  bool get _canStartImagePick => canRetainDocument(
    currentBytes: _retainedDocumentBytes,
    currentPages: _pages.length,
    incomingBytes: 1,
  );

  void _showDocumentLimit() {
    _showMessage(
      'Document memory limit reached. Remove pages before adding more.',
    );
  }

  bool _tryAddPage(ScannedPage page, {required int documentGeneration}) {
    if (_isClearingDraft ||
        !mounted ||
        documentGeneration != _documentGeneration) {
      return false;
    }
    if (!canRetainDocument(
      currentBytes: _retainedDocumentBytes,
      currentPages: _pages.length,
      incomingBytes: _pageMemoryBytes(page),
    )) {
      _showDocumentLimit();
      return false;
    }
    setState(() => _pages.add(page));
    _queueDraftSave();
    return true;
  }

  void _showMessage(String message) => showTransientMessage(context, message);

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
            const Text('FOSScanner'),
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
              InkWell(
                onTap: _openSourceCode,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.code,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'View source code',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
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

  Future<void> _captureImage() async {
    if (_isPickingImages || _isClearingDraft) return;
    if (!_canStartImagePick) {
      _showDocumentLimit();
      return;
    }
    final documentGeneration = _documentGeneration;
    setState(() => _isPickingImages = true);
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: maxPickerEdge,
        maxHeight: maxPickerEdge,
      );
      if (photo == null) return;
      // Camera capture writes a fresh file that's genuinely ours to delete.
      await _addCapturedPhoto(
        photo,
        deleteAfterRead: true,
        documentGeneration: documentGeneration,
      );
    } catch (error) {
      if (_isDefinitiveCameraUnavailable(error) && mounted) {
        setState(() => _cameraSupported = false);
      }
      _showMessage('Could not open the camera.');
    } finally {
      if (mounted) setState(() => _isPickingImages = false);
    }
  }

  Future<void> _importFromGallery() async {
    if (_isPickingImages || _isClearingDraft) return;
    if (!_canStartImagePick) {
      _showDocumentLimit();
      return;
    }
    final documentGeneration = _documentGeneration;
    setState(() => _isPickingImages = true);
    try {
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

  /// Shared by camera capture and gallery import: read the file's bytes,
  /// optionally delete the source file, then (native only) run the photo
  /// through the detect/adjust flow before adding it as a page.
  Future<_PhotoIntakeResult> _addCapturedPhoto(
    XFile photo, {
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
          currentBytes: _retainedDocumentBytes,
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
      currentBytes: _retainedDocumentBytes,
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
      _showMessage(
        'This image has unsupported dimensions. Choose an image from 3x3 '
        'up to ${maxSourceImageEdge}px per edge and '
        '$maxSourceImagePixels pixels.',
      );
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

    if (kIsWeb) {
      // opencv_dart doesn't support web; use the photo as-is rather than
      // offering a detect/adjust flow we can't actually run.
      final added = _tryAddPage(
        ScannedPage(
          originalBytes: bytes,
          corners: const [],
          processedBytes: bytes,
        ),
        documentGeneration: documentGeneration,
      );
      return added
          ? _PhotoIntakeResult.added
          : _PhotoIntakeResult.capacityReached;
    }

    if (!canProcessSourceImage(
      currentRetainedBytes: _retainedDocumentBytes,
      encodedBytes: bytes.length,
      size: imageSize,
    )) {
      _showMessage(
        'This image needs too much temporary memory to process safely. '
        'Remove pages or choose a smaller image.',
      );
      return _PhotoIntakeResult.skipped;
    }

    final result = await Navigator.of(context).push<ScannedPage>(
      MaterialPageRoute(
        builder: (_) => CornerAdjustScreen(
          originalBytes: bytes,
          operations: widget.cornerAdjustOperations,
          processingQueue: _imageProcessingQueue,
        ),
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

  Future<void> _editPage(int index) async {
    // No detect/adjust flow on web (see _addCapturedPhoto) — nothing to edit.
    if (kIsWeb ||
        _isClearingDraft ||
        _isOpeningEditor ||
        index < 0 ||
        index >= _pages.length) {
      return;
    }

    // Acquire this home page's editor lock before metadata loading yields.
    // This blocks stale, rapid card taps from starting overlapping routes.
    setState(() => _isOpeningEditor = true);
    try {
      final page = _pages[index];
      final documentGeneration = _documentGeneration;
      bool requestIsCurrent() =>
          mounted &&
          !_isClearingDraft &&
          documentGeneration == _documentGeneration &&
          index < _pages.length &&
          identical(_pages[index], page);

      late final Size imageSize;
      try {
        imageSize = await widget.sourceImageSizeReader(page.originalBytes);
        validateSourceImageSize(imageSize);
      } on UnsupportedError {
        if (!requestIsCurrent()) return;
        _showMessage(
          'This image has unsupported dimensions. Choose an image from 3x3 '
          'up to ${maxSourceImageEdge}px per edge and '
          '$maxSourceImagePixels pixels.',
        );
        return;
      } catch (_) {
        if (requestIsCurrent()) _showMessage('Could not read this photo.');
        return;
      }
      if (!requestIsCurrent()) return;
      if (!canProcessSourceImage(
        currentRetainedBytes: _retainedDocumentBytes,
        // The source is already part of the retained document total.
        encodedBytes: 0,
        size: imageSize,
      )) {
        _showMessage(
          'This image needs too much temporary memory to process safely. '
          'Remove pages or choose a smaller image.',
        );
        return;
      }
      if (!mounted) return;

      final result = await Navigator.of(context).push<ScannedPage>(
        MaterialPageRoute(
          builder: (_) => CornerAdjustScreen(
            originalBytes: page.originalBytes,
            initialCorners: page.corners,
            initialFilter: page.filter,
            initialRotationQuarterTurns: page.rotationQuarterTurns,
            initialBrightness: page.brightness,
            initialContrast: page.contrast,
            operations: widget.cornerAdjustOperations,
            processingQueue: _imageProcessingQueue,
          ),
        ),
      );
      if (result != null &&
          mounted &&
          !_isClearingDraft &&
          documentGeneration == _documentGeneration &&
          index < _pages.length &&
          identical(_pages[index], page)) {
        if (!canReplaceDocumentPage(
          currentBytes: _retainedDocumentBytes,
          currentPages: _pages.length,
          replacedBytes: _pageMemoryBytes(page),
          replacementBytes: _pageMemoryBytes(result),
        )) {
          _showDocumentLimit();
          return;
        }
        setState(() => _pages[index] = result);
        _queueDraftSave();
      }
    } finally {
      if (mounted) {
        setState(() => _isOpeningEditor = false);
      } else {
        _isOpeningEditor = false;
      }
    }
  }

  void _removePage(int index) {
    if (_isClearingDraft ||
        _isOpeningEditor ||
        index < 0 ||
        index >= _pages.length) {
      return;
    }
    final removed = _pages[index];
    final undoGeneration = ++_undoGeneration;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    setState(() => _pages.removeAt(index));
    _queueDraftSave();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Page deleted.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted ||
                _isClearingDraft ||
                undoGeneration != _undoGeneration) {
              return;
            }
            if (!canRetainDocument(
              currentBytes: _retainedDocumentBytes,
              currentPages: _pages.length,
              incomingBytes: _pageMemoryBytes(removed),
            )) {
              _showDocumentLimit();
              return;
            }
            final restoredIndex = index > _pages.length ? _pages.length : index;
            setState(() => _pages.insert(restoredIndex, removed));
            _queueDraftSave();
          },
        ),
      ),
    );
  }

  void _reorderPage(int fromIndex, int toIndex) {
    if (_isClearingDraft ||
        _isOpeningEditor ||
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
  }

  Future<void> _clearPages() async {
    if (_isClearingDraft) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all pages?'),
        content: const Text('This removes every page from the current draft.'),
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
    if (confirmed != true || !mounted || _isClearingDraft) return;
    await _clearCurrentDraft();
  }

  Future<void> _clearCurrentDraft() async {
    if (_isClearingDraft) return;
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
      _undoGeneration++;
      ScaffoldMessenger.of(context).clearSnackBars();
    }
    setState(() {
      if (cleared) _pages.clear();
      _isClearingDraft = false;
    });
  }

  Future<void> _askWhetherToKeepDraft() async {
    if (_isClearingDraft || _pages.isEmpty) return;
    final clear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Keep this draft?'),
        content: const Text(
          'The PDF was shared. You can keep these pages for later or clear the draft now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep draft'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear draft'),
          ),
        ],
      ),
    );
    if (clear != true || !mounted || _isClearingDraft) return;
    await _clearCurrentDraft();
  }

  Future<void> _generateAndSharePdf() async {
    if (_pages.isEmpty || _isClearingDraft) return;

    setState(() {
      _isGeneratingPdf = true;
    });

    var shared = false;
    try {
      // Capture the iPad popover anchor before PDF encoding yields; the page
      // list can change while encoding, which may remove the share button.
      final shareButtonBox =
          _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
      final shareOrigin = shareButtonBox == null
          ? null
          : shareButtonBox.localToGlobal(Offset.zero) & shareButtonBox.size;
      final pdf = pw.Document();

      for (final page in _pages) {
        final image = pw.MemoryImage(page.processedBytes);
        // Size the page to the image's own aspect ratio (at an assumed
        // scan resolution, so the physical page size stays reasonable)
        // instead of a fixed PdfPageFormat.a4 — that letterboxed the
        // image inside A4's fixed proportions (plus a built-in ~2cm
        // margin on top), which is exactly the "extra white border
        // around the selected document" users were seeing.
        final pageFormat = PdfPageFormat(
          image.width! / _scanDpi * PdfPageFormat.inch,
          image.height! / _scanDpi * PdfPageFormat.inch,
        );
        pdf.addPage(
          pw.Page(
            pageFormat: pageFormat,
            margin: pw.EdgeInsets.zero,
            build: (pw.Context context) => pw.Image(image, fit: pw.BoxFit.fill),
          ),
        );
      }

      // Start from bytes rather than creating our own persistent document.
      // share_plus may materialize an OS-managed cache copy for the receiver.
      final pdfBytes = await pdf.save();
      final fileName =
          'FOSScanner_${DateTime.now().millisecondsSinceEpoch}.pdf';

      final shareResult = await _sharePlus.share(
        ShareParams(
          files: [
            XFile.fromData(
              pdfBytes,
              name: fileName,
              mimeType: 'application/pdf',
            ),
          ],
          fileNameOverrides: [fileName],
          text: 'Document scanned with FOSScanner',
          // Required for the popover anchor on iPad; omitting it can make the
          // share sheet hang or crash instead of appearing.
          sharePositionOrigin: shareOrigin,
          // On web, sharing needs a secure context (HTTPS/localhost); when
          // unavailable, share_plus falls back to a plain browser download
          // so the user still gets their PDF instead of hitting a dead end.
          downloadFallbackEnabled: true,
        ),
      );
      // Some platforms cannot report a result and return `unavailable` even
      // after presenting the share UI. Only an explicit dismissal means the
      // user definitely did not share or download the PDF.
      shared = shareResult.status != ShareResultStatus.dismissed;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error generating PDF: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPdf = false;
        });
      }
    }
    if (shared && mounted && !_isClearingDraft && _pages.isNotEmpty) {
      await _askWhetherToKeepDraft();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FOSScanner'),
        actions: [
          // flutter_zxing has no web decoding backend (its web implementation
          // throws UnimplementedError on every frame) — same platform gap as
          // opencv_dart, so this follows the same kIsWeb convention used for
          // the detect/adjust flow elsewhere in this screen.
          if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BarcodeScanScreen()),
              ),
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
          if (_pages.isNotEmpty)
            IconButton(
              icon: _isClearingDraft
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.clear_all),
              onPressed: _isClearingDraft ? null : _clearPages,
              tooltip: 'Clear all',
            ),
        ],
      ),
      body: _pages.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _cameraSupported
                          ? Icons.camera_alt
                          : Icons.photo_library_outlined,
                      size: 80,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Ready to Scan',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _cameraSupported
                          ? 'Tap the camera button to add your first document. FOSS & Privacy-first: everything is processed on your device.'
                          : 'Import from your gallery to add your first document. FOSS & Privacy-first: everything is processed on your device.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.7,
              ),
              itemCount: _pages.length,
              itemBuilder: (context, index) {
                final page = _pages[index];
                final card = Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _isClearingDraft || _isOpeningEditor
                        ? null
                        : () => _editPage(index),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image(
                          image: ResizeImage(
                            MemoryImage(page.processedBytes),
                            width: _thumbnailCacheWidth,
                            height: _thumbnailCacheWidth,
                            policy: ResizeImagePolicy.fit,
                          ),
                          fit: BoxFit.cover,
                        ),
                        Positioned(
                          top: 8,
                          left: 8,
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.delete,
                                color: Colors.white,
                              ),
                              tooltip: 'Delete page ${index + 1}',
                              onPressed: _isClearingDraft || _isOpeningEditor
                                  ? null
                                  : () => _removePage(index),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );

                // Drag-to-reorder: long-press a page to pick it up, drop it
                // on another page's slot to swap it into that position.
                return DragTarget<int>(
                  onWillAcceptWithDetails: (details) =>
                      !_isClearingDraft &&
                      !_isOpeningEditor &&
                      details.data != index,
                  onAcceptWithDetails: (details) =>
                      _reorderPage(details.data, index),
                  builder: (context, candidateData, rejectedData) {
                    final isDropTarget = candidateData.isNotEmpty;
                    return LongPressDraggable<int>(
                      data: index,
                      maxSimultaneousDrags: _isClearingDraft || _isOpeningEditor
                          ? 0
                          : 1,
                      feedback: SizedBox(
                        width: 140,
                        height: 200,
                        child: Material(
                          color: Colors.transparent,
                          child: Opacity(opacity: 0.85, child: card),
                        ),
                      ),
                      childWhenDragging: Opacity(opacity: 0.3, child: card),
                      child: isDropTarget
                          ? Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 3,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: card,
                            )
                          : card,
                    );
                  },
                );
              },
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
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_pages.isNotEmpty) ...[
                ElevatedButton.icon(
                  key: _shareButtonKey,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _isGeneratingPdf || _isClearingDraft
                      ? null
                      : _generateAndSharePdf,
                  icon: _isGeneratingPdf || _isClearingDraft
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf),
                  label: Text(
                    _isClearingDraft
                        ? 'Clearing draft...'
                        : _isGeneratingPdf
                        ? 'Generating PDF...'
                        : 'Save as PDF (${_pages.length} pages)',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              TextButton(
                onPressed: _showAppInfo,
                child: Text(
                  'About FOSScanner',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
