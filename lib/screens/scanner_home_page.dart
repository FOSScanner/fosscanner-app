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
import '../services/image_metadata.dart';
import 'corner_adjust_screen.dart';

const _thumbnailCacheWidth = 512;
const _sourceCodeUrl = 'https://github.com/FOSScanner/fosscanner-app';

class _DocumentCapacityException implements Exception {
  const _DocumentCapacityException();
}

enum _PhotoIntakeResult { added, skipped, capacityReached }

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({
    super.key,
    this.initialPages = const [],
    this.sharePlus,
  });

  final List<ScannedPage> initialPages;
  final SharePlus? sharePlus;

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
  final GlobalKey _shareButtonKey = GlobalKey();
  bool _isGeneratingPdf = false;
  bool _isPickingImages = false;
  late bool _cameraSupported;

  @override
  void initState() {
    super.initState();
    _pages = [...widget.initialPages];
    _sharePlus = widget.sharePlus ?? SharePlus.instance;
    _cameraSupported = _picker.supportsImageSource(ImageSource.camera);
    // Android can destroy MainActivity while the system picker/camera is in
    // front. image_picker stores that pending result for the restarted app,
    // but it is lost permanently unless retrieveLostData is called at startup.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_recoverLostImages());
    }
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

  bool _tryAddPage(ScannedPage page) {
    if (!canRetainDocument(
      currentBytes: _retainedDocumentBytes,
      currentPages: _pages.length,
      incomingBytes: _pageMemoryBytes(page),
    )) {
      _showDocumentLimit();
      return false;
    }
    setState(() => _pages.add(page));
    return true;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    // Startup lost-data recovery can fail from initState, before this page's
    // Scaffold has registered with the surrounding ScaffoldMessenger.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Future<void> _showAppInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'FOSScanner',
      applicationVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
      applicationLegalese: 'Licensed under the GNU GPL v3.0',
      children: [
        const SizedBox(height: 16),
        InkWell(
          onTap: () => launchUrl(
            Uri.parse(_sourceCodeUrl),
            mode: LaunchMode.externalApplication,
          ),
          child: Text(
            _sourceCodeUrl,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _recoverLostImages() async {
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

  // Best-effort cleanup: FOSScanner doesn't persist scanned pages, so the
  // temp file image_picker writes on capture is deleted the moment we've
  // read its bytes into memory.
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
    if (_isPickingImages) return;
    if (!_canStartImagePick) {
      _showDocumentLimit();
      return;
    }
    setState(() => _isPickingImages = true);
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: maxPickerEdge,
        maxHeight: maxPickerEdge,
      );
      if (photo == null) return;
      // Camera capture writes a fresh file that's genuinely ours to delete.
      await _addCapturedPhoto(photo, deleteAfterRead: true);
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
    if (_isPickingImages) return;
    if (!_canStartImagePick) {
      _showDocumentLimit();
      return;
    }
    setState(() => _isPickingImages = true);
    try {
      final List<XFile> photos = await _picker.pickMultiImage(
        maxWidth: maxPickerEdge,
        maxHeight: maxPickerEdge,
        limit: maxDocumentPages - _pages.length,
      );
      for (final photo in photos) {
        if (!_canStartImagePick) {
          _showDocumentLimit();
          break;
        }
        // Unlike camera capture, a gallery pick's path isn't reliably an
        // app-owned temp copy across platforms — don't risk deleting a file
        // that might actually be the user's original photo.
        final result = await _addCapturedPhoto(photo, deleteAfterRead: false);
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
  }) async {
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
        'This image has dimensions too large to process safely. Choose an '
        'image up to ${maxSourceImageEdge}px per edge and '
        '$maxSourceImagePixels pixels.',
      );
      return _PhotoIntakeResult.skipped;
    } catch (_) {
      _showMessage('Could not read this photo.');
      return _PhotoIntakeResult.skipped;
    }
    if (!mounted) return _PhotoIntakeResult.skipped;

    if (kIsWeb) {
      // opencv_dart doesn't support web; use the photo as-is rather than
      // offering a detect/adjust flow we can't actually run.
      final added = _tryAddPage(
        ScannedPage(
          originalBytes: bytes,
          corners: const [],
          processedBytes: bytes,
        ),
      );
      return added
          ? _PhotoIntakeResult.added
          : _PhotoIntakeResult.capacityReached;
    }

    final result = await Navigator.of(context).push<ScannedPage>(
      MaterialPageRoute(
        builder: (_) => CornerAdjustScreen(originalBytes: bytes),
      ),
    );
    if (result == null || !mounted) return _PhotoIntakeResult.skipped;
    return _tryAddPage(result)
        ? _PhotoIntakeResult.added
        : _PhotoIntakeResult.capacityReached;
  }

  Future<void> _editPage(int index) async {
    // No detect/adjust flow on web (see _addCapturedPhoto) — nothing to edit.
    if (kIsWeb) return;

    final page = _pages[index];
    final result = await Navigator.of(context).push<ScannedPage>(
      MaterialPageRoute(
        builder: (_) => CornerAdjustScreen(
          originalBytes: page.originalBytes,
          initialCorners: page.corners,
          initialFilter: page.filter,
          initialRotationQuarterTurns: page.rotationQuarterTurns,
          initialBrightness: page.brightness,
          initialContrast: page.contrast,
        ),
      ),
    );
    if (result != null &&
        mounted &&
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
    }
  }

  void _removePage(int index) {
    setState(() => _pages.removeAt(index));
  }

  void _reorderPage(int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return;
    setState(() {
      final page = _pages.removeAt(fromIndex);
      _pages.insert(toIndex, page);
    });
  }

  void _clearPages() {
    setState(() => _pages.clear());
  }

  Future<void> _generateAndSharePdf() async {
    if (_pages.isEmpty) return;

    setState(() {
      _isGeneratingPdf = true;
    });

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

      await _sharePlus.share(
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FOSScanner'),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _isPickingImages || !_canStartImagePick
                ? null
                : _importFromGallery,
            tooltip: 'Import from gallery',
          ),
          if (_pages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              onPressed: _clearPages,
              tooltip: 'Clear all',
            ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showAppInfo,
            tooltip: 'About FOSScanner',
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
                    onTap: () => _editPage(index),
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
                              onPressed: () => _removePage(index),
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
                  onWillAcceptWithDetails: (details) => details.data != index,
                  onAcceptWithDetails: (details) =>
                      _reorderPage(details.data, index),
                  builder: (context, candidateData, rejectedData) {
                    final isDropTarget = candidateData.isNotEmpty;
                    return LongPressDraggable<int>(
                      data: index,
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
              onPressed: _isPickingImages || !_canStartImagePick
                  ? null
                  : _captureImage,
              tooltip: 'Capture Image',
              child: const Icon(Icons.camera_alt),
            )
          : null,
      bottomNavigationBar: _pages.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton.icon(
                  key: _shareButtonKey,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _isGeneratingPdf ? null : _generateAndSharePdf,
                  icon: _isGeneratingPdf
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf),
                  label: Text(
                    _isGeneratingPdf
                        ? 'Generating PDF...'
                        : 'Save as PDF (${_pages.length} pages)',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
