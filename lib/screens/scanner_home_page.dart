import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, OrdinalSortKey, SemanticsService;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/scanned_page.dart';
import '../services/app_preferences.dart';
import '../services/app_settings.dart';
import '../services/cache_copies.dart';
import '../services/document_memory.dart';
import '../services/draft_store.dart';
import '../services/image_metadata.dart';
import '../services/image_pdf_service.dart' as image_pdf;
import '../services/intake_report.dart';
import '../services/ocr_service.dart' as ocr_service;
import '../services/pdf_document_saver.dart';
import '../services/pdf_export_files.dart';
import '../services/pdf_export_options.dart';
import '../services/pdf_page_importer.dart';
import '../services/platform_capabilities.dart';
import '../services/screen_privacy.dart' as screen_privacy;
import '../services/shared_image_inbox.dart';
import '../widgets/pdf_import_progress_dialog.dart';
import '../widgets/screen_privacy_menu.dart';
import '../widgets/transient_message.dart';
import 'barcode_scan_screen.dart';
import 'corner_adjust_screen.dart';
import 'page_preview_screen.dart';

const _thumbnailCacheWidth = 512;

/// Page cards never grow wider than this: phones keep two columns, while
/// tablets and landscape windows get more columns instead of oversized cards.
const _maxPageCardExtent = 240.0;
const _pageGridSpacing = 8.0;
const _pageCardAspectRatio = 0.7;

/// The card footer (48 px controls), its 8 px inset and a thumbnail strip
/// that still shows which page it is.
const _minPageCardHeight = 72.0;

/// The camera button's 56 px plus its margin and a gap, so a card next to
/// or above it keeps every control uncovered.
const _cameraButtonClearance =
    56.0 + kFloatingActionButtonMargin + _pageGridSpacing;

/// Columns, card size and padding of the page grid for one viewport, and
/// the strip below it kept free for the camera button.
///
/// [cameraInset] is outside the scrolling area, so the camera button never
/// covers a card at any scroll position: tall viewports stop the grid above
/// the button, short ones keep a column beside it (in [padding]).
typedef _PageGridGeometry = ({
  int columns,
  Size cardSize,
  EdgeInsetsDirectional padding,
  double cameraInset,
});
const _sourceCodeUrl = 'https://github.com/FOSScanner/fosscanner-app';

class _DocumentCapacityException implements Exception {
  const _DocumentCapacityException();
}

enum _PhotoIntakeResult {
  added,

  /// The user skipped or cancelled the review.
  skipped,

  /// The image could not be added; the reason is in the intake report.
  rejected,

  /// The intake cannot continue (stopped, document full or cleared); the
  /// reason is in the intake report.
  ended,

  /// A camera page was added and the user asked to capture another one.
  addedScanNext,

  /// A camera capture was discarded and the user asked to capture it again.
  retake,
}

enum _CameraRecovery { retry, gallery, settings }

/// Which exporter owns the running PDF generation, and therefore how a
/// cancellation has to reach it: the native renderer needs a channel message,
/// the Dart image-only exporter only polls the flag this screen already sets.
enum _PdfExporter { searchable, imageOnly }

/// What the running export job produces: a PDF for the share sheet or a
/// user-chosen document, or recognized text for the clipboard.
enum _ExportAction { share, save, copyText }

typedef SourceImageSizeReader = Future<Size> Function(Uint8List imageBytes);

/// [FloatingActionButtonLocation.endFloat], but always floating above the
/// space the export bar takes, whether or not the bar is shown.
///
/// The export bar only exists while the document has pages, so the standard
/// location would make the camera button jump when the first page is added
/// and back when the last one is removed. The page sets the estimated bar
/// height on every build; the tallest bar actually laid out for the same width
/// and estimate is remembered, so a bar taller than the estimate moves the
/// button at most once instead of on every empty/non-empty change.
class _ExportBarFabLocation extends StandardFabLocation with FabEndOffsetX {
  /// Estimated export bar height, excluding the bottom safe-area padding.
  double estimatedBarHeight = 0;

  ({double width, double estimate, double height})? _measured;

  @override
  double getOffsetY(ScaffoldPrelayoutGeometry geometry, double adjustment) {
    final scaffoldHeight = geometry.scaffoldSize.height;
    final width = geometry.scaffoldSize.width;
    final barHeight = scaffoldHeight - geometry.contentBottom;
    var reserved = estimatedBarHeight + geometry.minViewPadding.bottom;
    final measured = _measured;
    if (measured != null &&
        measured.width == width &&
        measured.estimate == estimatedBarHeight) {
      reserved = math.max(reserved, measured.height);
    }
    if (barHeight > reserved) {
      _measured = (
        width: width,
        estimate: estimatedBarHeight,
        height: barHeight,
      );
      reserved = barHeight;
    }
    // Same as FabFloatOffsetY, with the content bottom raised to the reserved
    // bar top even while the bar is absent.
    final contentBottom = math.min(
      geometry.contentBottom,
      scaffoldHeight - reserved,
    );
    final fabHeight = geometry.floatingActionButtonSize.height;
    final snackBarHeight = geometry.snackBarSize.height;
    final bottomSheetHeight = geometry.bottomSheetSize.height;
    final safeMargin = math.max(
      kFloatingActionButtonMargin,
      geometry.minViewPadding.bottom -
          (scaffoldHeight - contentBottom) +
          kFloatingActionButtonMargin,
    );
    var fabY = contentBottom - fabHeight - safeMargin;
    if (snackBarHeight > 0) {
      fabY = math.min(
        fabY,
        geometry.contentBottom -
            snackBarHeight -
            fabHeight -
            kFloatingActionButtonMargin,
      );
    }
    if (bottomSheetHeight > 0) {
      fabY = math.min(
        fabY,
        geometry.contentBottom - bottomSheetHeight - fabHeight / 2,
      );
    }
    return fabY + adjustment;
  }

  @override
  String toString() => 'FloatingActionButtonLocation.exportBarEndFloat';
}

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({
    super.key,
    this.initialPages = const [],
    this.sharePlus,
    this.searchablePdfEnabled,
    this.draftStore = const NoOpDraftStore(),
    this.cornerAdjustOperations = const DefaultCornerAdjustOperations(),
    this.sourceImageSizeReader = readEncodedImageSize,
    this.sharedImageInbox,
    this.pdfPageImporter,
    this.preferencesStore,
    this.temporaryDirectory = getTemporaryDirectory,
    this.documentSaver = const PlatformPdfDocumentSaver(),
    this.appSettingsOpener = openAppSettings,
  });

  final List<ScannedPage> initialPages;
  final SharePlus? sharePlus;
  final bool? searchablePdfEnabled;
  final DraftStore draftStore;
  final CornerAdjustOperations cornerAdjustOperations;
  final SourceImageSizeReader sourceImageSizeReader;

  /// Images shared into the app by other apps (Android only); null disables
  /// share intake.
  final SharedImageInbox? sharedImageInbox;

  /// Imports pages from a PDF (Android only); null hides the action.
  final PdfPageImporter? pdfPageImporter;

  /// Where export choices persist; defaults to memory only.
  final AppPreferencesStore? preferencesStore;

  /// The cache directory exported PDFs are written to before handing off.
  final DirectoryProvider temporaryDirectory;

  /// Saves exports to device storage where the platform supports it.
  final PdfDocumentSaver documentSaver;

  /// Opens the app's system settings, to turn camera access back on.
  final AppSettingsOpener appSettingsOpener;

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
  late final AppPreferencesStore _preferencesStore;
  AppPreferences _preferences = const AppPreferences();
  // Set once the user changes a preference, so a slow initial load cannot
  // overwrite a choice made while it was still reading.
  bool _preferencesChanged = false;
  final _fabLocation = _ExportBarFabLocation();
  final _gridScroll = ScrollController();
  // The page grid's latest layout, used to scroll a page into view.
  _PageGridGeometry? _gridGeometry;
  bool _isGeneratingPdf = false;
  bool _isSharingPdf = false;
  // The name the user chose for a save in progress, once the picker returned.
  String? _saveTargetName;
  _ExportAction _exportAction = _ExportAction.share;
  bool _isCancellingPdf = false;
  double? _pdfProgress;
  _PdfExporter? _pdfExporter;
  bool _isPickingImages = false;
  bool _isRestoringDraft = false;
  bool _draftRestoreFailed = false;
  bool _isClearingDraft = false;
  bool _isOpeningImageRoute = false;
  // Shared images are waiting on the platform side. They are pulled only
  // when no draft decision, intake, editor, export or clear is in progress.
  bool _isSharedImageIntakePending = false;
  Timer? _sharedImageRetry;
  late bool _cameraSupported;
  // Session-only: a new page starts with the filter chosen for the previous
  // new page, so a multi-page scan needs the filter sheet only once. Edits of
  // existing pages keep their own filter and do not change this.
  PageFilter _lastNewPageFilter = PageFilter.original;

  @override
  void initState() {
    super.initState();
    _pages = [...widget.initialPages];
    _sharePlus = widget.sharePlus ?? SharePlus.instance;
    _preferencesStore = widget.preferencesStore ?? MemoryAppPreferencesStore();
    unawaited(_loadPreferences());
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
    final inbox = widget.sharedImageInbox;
    if (inbox != null) {
      inbox.setListener(_onSharedImagesAvailable);
      // A cold start may have been caused by a share; ask once the draft has
      // been restored so new pages are appended to it.
      _isSharedImageIntakePending = true;
      unawaited(_initialDraftRestore.then((_) => _resumeSharedImageIntake()));
    }
  }

  @override
  void dispose() {
    _gridScroll.dispose();
    _sharedImageRetry?.cancel();
    widget.sharedImageInbox?.setListener(null);
    super.dispose();
  }

  void _onSharedImagesAvailable() {
    _isSharedImageIntakePending = true;
    _resumeSharedImageIntake();
  }

  /// Starts pending shared-image intake once nothing else owns the screen.
  ///
  /// Every lock holder calls this when it finishes. A failed draft restore
  /// defers intake exactly like lost-image recovery: it resumes after the
  /// user retries restoration or discards the draft.
  void _resumeSharedImageIntake() {
    _sharedImageRetry?.cancel();
    _sharedImageRetry = null;
    final inbox = widget.sharedImageInbox;
    if (inbox == null || !mounted || !_isSharedImageIntakePending) return;
    if (_isRestoringDraft || _isDocumentInteractionLocked) return;
    if (ModalRoute.of(context)?.isCurrent == false) {
      // A dialog, menu or sheet is open over the home screen and does not
      // report when it closes; check again shortly.
      _sharedImageRetry = Timer(
        const Duration(milliseconds: 500),
        _resumeSharedImageIntake,
      );
      return;
    }
    _isSharedImageIntakePending = false;
    unawaited(_importSharedImages(inbox));
  }

  Future<void> _importSharedImages(SharedImageInbox inbox) async {
    final documentGeneration = _documentGeneration;
    setState(() => _isPickingImages = true);
    var paths = const <String>[];
    var nextPath = 0;
    try {
      await _imageProcessingQueue.idle;
      if (!mounted) return;
      final batch = await inbox.take(
        maxCount: math.max(0, maxDocumentPages - _pages.length),
      );
      paths = batch.paths;
      if (!mounted) return;
      if (_isClearingDraft || documentGeneration != _documentGeneration) {
        _logIntake(PageReviewSource.shared, 'all', 'document cleared');
        if (paths.isNotEmpty || batch.rejected > 0) {
          _showMessage(_discardedIntakeMessage);
        }
        return;
      }
      // Items the platform could not hand over are rejections of the same
      // share, reported in the one summary after the review.
      final report = IntakeReport(total: paths.length + batch.rejected)
        ..reject(IntakeRejection.unavailable, count: batch.rejected);
      nextPath = await _reviewBatch(
        [for (final path in paths) XFile(path)],
        source: PageReviewSource.shared,
        // The copies are app-owned cache files, deleted once read.
        deleteAfterRead: true,
        documentGeneration: documentGeneration,
        report: report,
      );
      if (batch.truncated) {
        report.end(
          'Some shared images were not added: page limit reached '
          '($maxDocumentPages pages).',
        );
      }
      _showIntakeReport(report);
    } on MissingPluginException {
      // No native share handler (tests, unsupported embedders).
    } catch (_) {
      _showMessage('Could not add the shared images.');
    } finally {
      for (final path in paths.skip(nextPath)) {
        await _deleteFileQuietly(path);
      }
      if (mounted) setState(() => _isPickingImages = false);
      // Another share may have arrived during this review.
      _resumeSharedImageIntake();
    }
  }

  Future<void> _loadPreferences() async {
    final loaded = await _preferencesStore.load();
    if (!mounted || _preferencesChanged) return;
    setState(() => _preferences = loaded);
    // The window starts unprotected each launch; re-apply the saved choice.
    if (loaded.blockScreenshots) _applySecureScreen(true);
  }

  void _setBlockScreenshots(bool enabled) {
    _updatePreferences(_preferences.copyWith(blockScreenshots: enabled));
    _applySecureScreen(enabled);
  }

  void _applySecureScreen(bool enabled) {
    unawaited(
      screen_privacy.setSecureScreen(enabled).catchError((Object error) {
        if (kDebugMode) {
          debugPrint('Could not change screen privacy (${error.runtimeType}).');
        }
      }),
    );
  }

  void _onOverflowSelected(String value) {
    if (_handlePdfImportMenuSelection(value)) return;
    switch (value) {
      case 'clear':
        _clearPages();
      case blockScreenshotsMenuValue:
        _setBlockScreenshots(!_preferences.blockScreenshots);
      case _:
        _showAppInfo();
    }
  }

  void _updatePreferences(AppPreferences next) {
    if (next == _preferences) return;
    _preferencesChanged = true;
    setState(() => _preferences = next);
    unawaited(
      _preferencesStore.save(next).catchError((Object error) {
        // The choice still applies for this session; only persistence failed.
        if (kDebugMode) {
          debugPrint('Could not save preferences (${error.runtimeType}).');
        }
      }),
    );
  }

  /// Whether the next export is searchable. Platforms without OCR ignore the
  /// stored choice rather than clearing it.
  bool get _exportsSearchable => _ocrSupported && _preferences.searchablePdf;

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
    _resumeIntakeAfterDraftDecision();
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
    _resumeIntakeAfterDraftDecision();
  }

  /// Lost-image recovery and shared images both wait while a failed draft
  /// awaits a decision. Recovery runs first: it takes the intake lock
  /// synchronously, so shared images resume when it finishes.
  void _resumeIntakeAfterDraftDecision() {
    if (!mounted || _draftRestoreFailed) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_recoverLostImages());
    }
    _resumeSharedImageIntake();
  }

  Widget _buildDraftRestoreFailure() => Scaffold(
    appBar: AppBar(title: const Text('FOSScanner')),
    body: Center(
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
              const CircularProgressIndicator(semanticsLabel: 'Opening draft'),
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

  /// Adds a reviewed page, or records in [report] why it could not be.
  bool _tryAddPage(
    ScannedPage page, {
    required int documentGeneration,
    required IntakeReport report,
  }) {
    if (!mounted ||
        _isClearingDraft ||
        documentGeneration != _documentGeneration) {
      report.end(_discardedIntakeMessage);
      return false;
    }
    if (_draftRestoreFailed || _isGeneratingPdf) {
      // Intake is locked in both states; this guards a stale review.
      report.end('Could not add the page. Try again.');
      return false;
    }
    if (!canRetainDocument(
      currentBytes: _retainedImageBytesFor([..._pages, page]),
      currentPages: _pages.length,
      incomingBytes: 0,
    )) {
      report.end(_documentLimitMessage);
      return false;
    }
    setState(() => _pages.add(page));
    _queueDraftSave();
    _revealPage(_pages.length - 1);
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
      if (!launched) _showMessage('Could not open the link.');
    } catch (_) {
      _showMessage('Could not open the link.');
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
                'Free and open-source document scanner. Scanning, text '
                'recognition and PDF export run on your device. No accounts, '
                'no cloud, no tracking.',
              ),
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _openSourceCode,
                icon: const Icon(Icons.code_outlined),
                label: const Text('View source code'),
              ),
              TextButton.icon(
                onPressed: () => showLicensePage(
                  context: dialogContext,
                  applicationName: 'FOSScanner',
                  applicationVersion: packageInfo.version,
                  applicationIcon: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.asset(
                      'assets/icon/icon.png',
                      width: 48,
                      height: 48,
                    ),
                  ),
                ),
                icon: const Icon(Icons.description_outlined),
                label: const Text('View licenses'),
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
    // Set while the lost result is left for after the draft decision; its
    // picker copies must survive until then.
    var deferred = false;
    try {
      // Restore the existing pages before admitting a recovered image so its
      // processing budget and next saved snapshot include the whole document.
      await _initialDraftRestore;
      if (!mounted) return;
      if (_draftRestoreFailed) {
        deferred = true;
        return;
      }
      final response = await _picker.retrieveLostData();
      if (!mounted || response.isEmpty) return;
      if (response.exception != null) {
        _showMessage('Could not recover the interrupted image selection.');
        return;
      }

      final files =
          response.files ?? [if (response.file != null) response.file!];
      final report = IntakeReport(total: files.length);
      var reviewed = 0;
      try {
        // Android image_picker recovery paths are app-owned cache copies.
        reviewed = await _reviewBatch(
          files,
          source: PageReviewSource.recovered,
          deleteAfterRead: true,
          documentGeneration: documentGeneration,
          report: report,
        );
      } finally {
        for (final remaining in files.skip(reviewed)) {
          await _deleteFileQuietly(remaining.path);
        }
      }
      _showIntakeReport(report);
    } catch (_) {
      _showMessage('Could not recover the interrupted image selection.');
    } finally {
      // Lost results have been read; remove copies earlier runs left behind.
      if (!deferred) {
        unawaited(
          sweepImagePickerCopies(temporaryDirectory: widget.temporaryDirectory),
        );
      }
      if (mounted) setState(() => _isPickingImages = false);
      _resumeSharedImageIntake();
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
        '$cameraAccessOffMessage You can also import images.',
      'camera_access_restricted' =>
        '$cameraAccessRestrictedMessage You can still import images.',
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
          // Once denied for good, only the settings page can turn it back on.
          if (code == 'camera_access_denied' && canOpenAppSettings)
            TextButton(
              onPressed: () => Navigator.pop(context, _CameraRecovery.settings),
              child: const Text('Open settings'),
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

  /// Continuous capture: after each camera review the user can add the page
  /// and scan the next one, or retake the photo. The loop ends when they
  /// choose Add page, leave the review, cancel the system camera, or the
  /// document is full. Accepted pages are kept in every case.
  ///
  /// If Android destroys the activity while the camera is open mid-loop, the
  /// pending photo is restored by [_recoverLostImages] as a single review; the
  /// loop itself is not resumed.
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
    // The shot discarded by Retake and its review, kept only until the next
    // capture so that cancelling the camera returns to that review, crop and
    // settings included, instead of losing it.
    Uint8List? retakenBytes;
    PageReviewState? retakenReview;
    try {
      for (var isFirstCapture = true; ; isFirstCapture = false) {
        if (!isFirstCapture) {
          if (!mounted ||
              _isClearingDraft ||
              documentGeneration != _documentGeneration) {
            return;
          }
          // Admission is re-checked before every relaunch: pages added in
          // this loop may have filled the document.
          if (!_canStartImagePick) {
            _showDocumentLimit();
            return;
          }
        }
        await _imageProcessingQueue.idle;
        if (!mounted || documentGeneration != _documentGeneration) return;
        final XFile? captured = await _picker.pickImage(
          source: ImageSource.camera,
          maxWidth: maxPickerEdge,
          maxHeight: maxPickerEdge,
        );
        final previous = retakenBytes;
        final previousReview = retakenReview;
        retakenBytes = null;
        retakenReview = null;
        if (captured == null && previous == null) return;
        // Camera capture writes a fresh file that's genuinely ours to delete.
        final report = IntakeReport(total: 1);
        final result = await _addCapturedPhoto(
          captured ?? XFile.fromData(previous!),
          source: PageReviewSource.camera,
          deleteAfterRead: captured != null,
          documentGeneration: documentGeneration,
          restoredReview: captured == null ? previousReview : null,
          onRetake: (bytes, review) {
            retakenBytes = bytes;
            retakenReview = review;
          },
          report: report,
        );
        _showIntakeReport(report);
        // Any other outcome ends the loop; it has just been reported.
        if (result != _PhotoIntakeResult.addedScanNext &&
            result != _PhotoIntakeResult.retake) {
          return;
        }
      }
    } catch (error) {
      if (!mounted) return;
      if (_isDefinitiveCameraUnavailable(error)) {
        setState(() => _cameraSupported = false);
      }
      recovery = await _showCameraFailure(error);
    } finally {
      if (mounted) setState(() => _isPickingImages = false);
      _resumeSharedImageIntake();
    }
    if (!mounted || documentGeneration != _documentGeneration) return;
    switch (recovery) {
      case _CameraRecovery.retry:
        await _captureImage();
      case _CameraRecovery.gallery:
        await _importFromGallery();
      case _CameraRecovery.settings:
        await widget.appSettingsOpener();
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
      final report = IntakeReport(total: photos.length);
      // Unlike camera capture, a gallery pick's path isn't reliably an
      // app-owned temp copy across platforms — don't risk deleting a file
      // that might actually be the user's original image.
      await _reviewBatch(
        photos,
        source: PageReviewSource.gallery,
        deleteAfterRead: false,
        documentGeneration: documentGeneration,
        report: report,
      );
      // Only image_picker's own cache copies (Android) are removed; the
      // user's originals are never touched.
      for (final photo in photos) {
        unawaited(
          deleteImagePickerCopy(
            photo.path,
            temporaryDirectory: widget.temporaryDirectory,
          ),
        );
      }
      _showIntakeReport(report);
    } catch (_) {
      _showMessage('Could not open the gallery.');
    } finally {
      // Copies of images that were skipped or not reached. Nothing is being
      // picked now, and a new pick takes far longer than this sweep.
      unawaited(
        sweepImagePickerCopies(temporaryDirectory: widget.temporaryDirectory),
      );
      if (mounted) setState(() => _isPickingImages = false);
      _resumeSharedImageIntake();
    }
  }

  static const _importPdfMenuValue = 'import_pdf';

  /// The overflow-menu entry for PDF import; empty where it is unsupported.
  List<PopupMenuEntry<String>> _pdfImportMenuItems() => [
    if (widget.pdfPageImporter != null)
      PopupMenuItem(
        value: _importPdfMenuValue,
        enabled: !_isPickingImages && !_isClearingDraft && _canStartImagePick,
        child: ListTile(
          enabled: !_isPickingImages && !_isClearingDraft && _canStartImagePick,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_open_outlined),
          title: const Text('Import from PDF'),
        ),
      ),
  ];

  /// Handles [value] if it is the PDF import entry.
  bool _handlePdfImportMenuSelection(String value) {
    if (value != _importPdfMenuValue) return false;
    unawaited(_importPdf());
    return true;
  }

  /// Picks a PDF, renders its pages natively, then reviews them one by one
  /// like a multi-image import. Pages start as full-image crops.
  Future<void> _importPdf() async {
    final importer = widget.pdfPageImporter;
    if (importer == null || _isRestoringDraft || _isDocumentInteractionLocked) {
      return;
    }
    if (!_canStartImagePick) {
      _showDocumentLimit();
      return;
    }
    final documentGeneration = _documentGeneration;
    setState(() => _isPickingImages = true);
    var paths = const <String>[];
    var nextPath = 0;
    bool isCurrent() =>
        mounted &&
        !_isClearingDraft &&
        documentGeneration == _documentGeneration;
    try {
      await _imageProcessingQueue.idle;
      if (!isCurrent()) return;
      if (!await importer.pickDocument() || !isCurrent()) return;
      // Limits are taken after the picker returns: they bound what is
      // rendered, so nothing is rendered that the document cannot hold.
      final request = PdfImportRequest.forDocument(
        quality: _preferences.pdfQuality,
        currentPages: _pages.length,
        retainedBytes: _retainedImageBytes,
      );
      if (request == null) {
        _showDocumentLimit();
        return;
      }
      final batch = await _renderPdfWithProgress(importer, request);
      paths = batch.paths;
      if (!mounted) return;
      if (!isCurrent()) {
        _logIntake(PageReviewSource.pdf, 'all', 'document cleared');
        _showMessage(_discardedIntakeMessage);
        return;
      }
      final report = IntakeReport(
        total: paths.length + batch.rejected,
        noun: 'page',
      )..reject(IntakeRejection.notRendered, count: batch.rejected);
      nextPath = await _reviewBatch(
        [for (final path in paths) XFile(path)],
        source: PageReviewSource.pdf,
        // The renders are app-owned cache files, deleted once read.
        deleteAfterRead: true,
        documentGeneration: documentGeneration,
        report: report,
      );
      // Reported after the review so the message never covers its buttons.
      if (batch.truncated) {
        report.end(
          batch.pageCount > request.maxPages
              ? 'Some PDF pages were not added: page limit reached '
                    '($maxDocumentPages pages).'
              : 'Some PDF pages were not added: document memory limit '
                    'reached.',
        );
      }
      _showIntakeReport(report);
    } on PdfImportException catch (error) {
      if (mounted) {
        _showMessage(switch (error.failure) {
          PdfImportFailure.unreadable => 'Could not open this PDF.',
          PdfImportFailure.cancelled => 'PDF import canceled',
          PdfImportFailure.failed => 'Could not import the PDF.',
        });
      }
    } on MissingPluginException {
      // No native PDF importer (tests, unsupported embedders).
    } catch (_) {
      if (mounted) _showMessage('Could not import the PDF.');
    } finally {
      for (final path in paths.skip(nextPath)) {
        await _deleteFileQuietly(path);
      }
      if (mounted) setState(() => _isPickingImages = false);
      _resumeSharedImageIntake();
    }
  }

  /// Renders under a cancellable modal dialog, inside the image processing
  /// queue so the native bitmaps never overlap an editor's work.
  Future<PdfImportBatch> _renderPdfWithProgress(
    PdfPageImporter importer,
    PdfImportRequest request,
  ) async {
    final progress = ValueNotifier<PdfImportProgress?>(null);
    var cancelRequested = false;
    var finished = false;
    final navigator = Navigator.of(context);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PdfImportProgressDialog(
        progress: progress,
        onCancel: () {
          cancelRequested = true;
          if (finished) return;
          unawaited(importer.cancel().catchError((Object _) {}));
        },
      ),
    );
    unawaited(navigator.push(route));
    try {
      return await _imageProcessingQueue.run(() async {
        if (cancelRequested) {
          throw const PdfImportException(PdfImportFailure.cancelled);
        }
        return importer.renderPages(
          request,
          onProgress: (completed, total) {
            if (!finished) {
              progress.value = PdfImportProgress(completed, total);
            }
          },
        );
      });
    } finally {
      finished = true;
      if (route.isCurrent) {
        navigator.pop();
      } else if (route.isActive) {
        navigator.removeRoute(route);
      }
    }
  }

  CornerAdjustScreen _buildEditor(
    Uint8List originalBytes, {
    ScannedPage? page,
    PageReviewSource? source,
    bool isBatchImport = false,
    int? batchPosition,
    int? batchCount,
    VoidCallback? onStopImport,
    VoidCallback? onScanNext,
    ValueChanged<PageReviewState>? onRetake,
    VoidCallback? onUnreadable,
    PageReviewState? restoredReview,
  }) {
    return CornerAdjustScreen(
      originalBytes: originalBytes,
      source: source,
      isBatchImport: isBatchImport,
      batchPosition: batchPosition,
      batchCount: batchCount,
      onStopImport: onStopImport,
      onScanNext: onScanNext,
      onRetake: onRetake,
      onUnreadable: onUnreadable,
      restoredReview: restoredReview,
      initialCorners: page?.corners,
      startWithAdjustments: page != null,
      // PDF pages are already flat: start from the full page.
      detectPageEdges: source != PageReviewSource.pdf,
      initialFilter: page?.filter ?? _lastNewPageFilter,
      initialRotationQuarterTurns: page?.rotationQuarterTurns ?? 0,
      initialBrightness: page?.brightness ?? 0,
      initialContrast: page?.contrast ?? 1,
      operations: widget.cornerAdjustOperations,
      processingQueue: _imageProcessingQueue,
    );
  }

  /// Reviews [files] one at a time, recording in [report] each file that is
  /// not added and why. Stops early when the user stops the import or the
  /// document is full. Returns how many files were taken from [files]; the
  /// rest were never read.
  Future<int> _reviewBatch(
    List<XFile> files, {
    required PageReviewSource source,
    required bool deleteAfterRead,
    required int documentGeneration,
    required IntakeReport report,
  }) async {
    var next = 0;
    while (next < files.length && mounted && !report.hasOutcome) {
      final index = next++;
      if (!canRetainDocument(
        currentBytes: _retainedImageBytes,
        currentPages: _pages.length,
        incomingBytes: 1,
      )) {
        _logIntake(source, '${index + 1}/${files.length}', 'document full');
        report.end(_documentLimitMessage);
        // Not read: the caller deletes app-owned files from here on.
        return index;
      }
      await _addCapturedPhoto(
        files[index],
        source: source,
        isBatchImport: files.length > 1,
        batchPosition: index + 1,
        batchCount: files.length,
        deleteAfterRead: deleteAfterRead,
        documentGeneration: documentGeneration,
        report: report,
      );
    }
    return next;
  }

  static const _discardedIntakeMessage =
      'Import canceled because the pages were cleared.';

  /// Debug builds only: why an intake item was not added. Never logs paths
  /// or image content.
  void _logIntake(PageReviewSource source, String item, String outcome) {
    if (kDebugMode) debugPrint('Intake ${source.name} $item: $outcome.');
  }

  /// Shows the one message summarizing an intake, if it needs one.
  void _showIntakeReport(IntakeReport report) {
    final message = report.message;
    if (message != null && mounted) _showMessage(message);
  }

  /// Shared by camera capture and gallery import: read the file's bytes,
  /// optionally delete the source file, then (native only) run the photo
  /// through the detect/adjust flow before adding it as a page.
  ///
  /// Nothing is shown here: why an image was not added goes into [report],
  /// which the caller shows once the whole intake has been reviewed.
  Future<_PhotoIntakeResult> _addCapturedPhoto(
    XFile photo, {
    required PageReviewSource source,
    required IntakeReport report,
    bool isBatchImport = false,
    int? batchPosition,
    int? batchCount,
    required bool deleteAfterRead,
    required int documentGeneration,
    void Function(Uint8List bytes, PageReviewState review)? onRetake,
    PageReviewState? restoredReview,
  }) async {
    // Every way out that does not add a page is recorded in [report] (or is
    // the user's own Skip) and logged in debug builds.
    final item = '${batchPosition ?? 1}/${batchCount ?? 1}';
    _PhotoIntakeResult reject(IntakeRejection reason) {
      _logIntake(source, item, reason.name);
      report.reject(reason);
      return _PhotoIntakeResult.rejected;
    }

    _PhotoIntakeResult end(String outcome, String message) {
      _logIntake(source, item, outcome);
      report.end(message);
      return _PhotoIntakeResult.ended;
    }

    _PhotoIntakeResult reachLimit() =>
        end('document full', _documentLimitMessage);

    _PhotoIntakeResult discard() =>
        end('document cleared', _discardedIntakeMessage);

    bool isStale() =>
        !mounted ||
        _isClearingDraft ||
        documentGeneration != _documentGeneration;

    if (isStale()) {
      if (deleteAfterRead) await _deleteFileQuietly(photo.path);
      return discard();
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
      return reachLimit();
    } on EncodedImageTooLargeError {
      return reject(IntakeRejection.fileTooLarge);
    } catch (_) {
      return reject(IntakeRejection.unreadable);
    }

    if (isStale()) return discard();
    if (!canRetainDocument(
      currentBytes: _retainedImageBytes,
      currentPages: _pages.length,
      incomingBytes: bytes.length,
    )) {
      return reachLimit();
    }

    late final Size imageSize;
    try {
      imageSize = await readEncodedImageSize(bytes);
      validateSourceImageSize(imageSize);
    } on UnsupportedError {
      return reject(IntakeRejection.unsupportedSize);
    } catch (_) {
      return reject(IntakeRejection.notImage);
    }
    if (!mounted ||
        _isClearingDraft ||
        documentGeneration != _documentGeneration) {
      return discard();
    }

    if (!canProcessSourceImage(
      currentRetainedBytes: _retainedImageBytes,
      encodedBytes: bytes.length,
      size: imageSize,
    )) {
      return reject(IntakeRejection.needsTooMuchMemory);
    }

    var stopRequested = false;
    var scanNextRequested = false;
    PageReviewState? retakeReview;
    var unreadable = false;
    // Only camera capture loops back into the picker.
    final isCamera = source == PageReviewSource.camera;
    final result = await Navigator.of(context).push<ScannedPage>(
      MaterialPageRoute(
        builder: (_) => _buildEditor(
          bytes,
          source: source,
          isBatchImport: isBatchImport,
          batchPosition: batchPosition,
          batchCount: batchCount,
          onStopImport: () => stopRequested = true,
          onScanNext: isCamera ? () => scanNextRequested = true : null,
          onRetake: isCamera ? (review) => retakeReview = review : null,
          onUnreadable: () => unreadable = true,
          restoredReview: restoredReview,
        ),
      ),
    );
    // The editor could not decode it: not the user's Skip, and reported
    // even when the user then stops the import.
    if (unreadable && result == null) reject(IntakeRejection.unreadable);
    if (stopRequested) {
      return end('stopped', 'Import stopped. Pages already added were kept.');
    }
    if (retakeReview != null && result == null) {
      onRetake?.call(bytes, retakeReview!);
      return _PhotoIntakeResult.retake;
    }
    if (unreadable && result == null) return _PhotoIntakeResult.rejected;
    if (result == null) {
      // Skip, Cancel, or back: the user's choice, so nothing to report.
      _logIntake(source, item, 'left the review without adding');
      return _PhotoIntakeResult.skipped;
    }
    if (!_tryAddPage(
      result,
      documentGeneration: documentGeneration,
      report: report,
    )) {
      _logIntake(source, item, 'not added after review');
      return _PhotoIntakeResult.ended;
    }
    _lastNewPageFilter = result.filter;
    return scanNextRequested
        ? _PhotoIntakeResult.addedScanNext
        : _PhotoIntakeResult.added;
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
      _resumeSharedImageIntake();
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
        _showMessage(intakeRejectionMessage(IntakeRejection.unsupportedSize));
        return;
      } catch (_) {
        if (requestIsCurrent()) {
          _showMessage(intakeRejectionMessage(IntakeRejection.unreadable));
        }
        return;
      }
      if (!requestIsCurrent()) return;
      if (!canProcessSourceImage(
        currentRetainedBytes: _retainedImageBytes,
        // The source is already part of the retained document total.
        encodedBytes: 0,
        size: imageSize,
      )) {
        _showMessage(
          intakeRejectionMessage(IntakeRejection.needsTooMuchMemory),
        );
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
      _resumeSharedImageIntake();
    }
  }

  /// Long enough to notice a mistaken delete and reach Undo.
  static const _undoDuration = Duration(seconds: 10);

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
    // Screen-reader users reach Undo at their own pace: it stays until they
    // use or close it.
    final persist = MediaQuery.accessibleNavigationOf(context);
    final controller = messenger.showSnackBar(
      SnackBar(
        content: const Text('Page deleted'),
        // Floating snackbars sit above the camera button instead of lifting
        // it. The button never moves, so Undo keeps one position while it
        // appears, while it is reachable and while it leaves, whether or not
        // the export bar is shown; the button cannot slide into its place.
        behavior: SnackBarBehavior.floating,
        // Flutter otherwise makes action snackbars persistent by default.
        persist: persist,
        showCloseIcon: persist,
        duration: _undoDuration,
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
            _revealPage(restoredIndex);
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

  /// Shown, disabled, even for a single page so every card footer has the
  /// same layout and adding the second page does not resize the thumbnails.
  Widget _pageReorderMenu(int index, ScannedPage page) => PopupMenuButton<int>(
    tooltip: 'Reorder page ${index + 1}',
    icon: const Icon(Icons.swap_vert),
    enabled: !_isDocumentInteractionLocked && _pages.length > 1,
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

  /// Scrolls the grid just enough to show the page at [index] whole and clear
  /// of the camera button. A page already in view does not move. While a
  /// review route still covers the grid, this waits until it has closed, so
  /// the user sees where the page went; reduced motion jumps instead.
  void _revealPage(int index) {
    final covering = ModalRoute.of(context)?.secondaryAnimation;
    if (covering != null && !covering.isDismissed) {
      void onStatus(AnimationStatus status) {
        if (!status.isDismissed) return;
        covering.removeStatusListener(onStatus);
        if (mounted) _revealPage(index);
      }

      covering.addStatusListener(onStatus);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final geometry = _gridGeometry;
      if (!mounted ||
          geometry == null ||
          !_gridScroll.hasClients ||
          index >= _pages.length) {
        return;
      }
      final position = _gridScroll.position;
      final padding = geometry.padding;
      final row = index ~/ geometry.columns;
      final top =
          padding.top + row * (geometry.cardSize.height + _pageGridSpacing);
      final bottom = top + geometry.cardSize.height;
      final double target;
      // A card taller than the viewport is shown from its top and never
      // scrolled past it, so it cannot jump between top and bottom.
      final fits =
          padding.top + geometry.cardSize.height + padding.bottom <=
          position.viewportDimension;
      if (top - padding.top < position.pixels ||
          (!fits && top - padding.top > position.pixels)) {
        target = top - padding.top;
      } else if (bottom + padding.bottom >
          position.pixels + position.viewportDimension) {
        target = bottom + padding.bottom - position.viewportDimension;
      } else {
        return;
      }
      // A lazily built grid only estimates its extent until its last row is
      // laid out, so the exact end comes from the grid's own geometry.
      final rows = (_pages.length / geometry.columns).ceil();
      final contentHeight =
          padding.top +
          rows * geometry.cardSize.height +
          math.max(0, rows - 1) * _pageGridSpacing +
          padding.bottom;
      final offset = target
          .clamp(0.0, math.max(0.0, contentHeight - position.viewportDimension))
          .toDouble();
      if ((offset - position.pixels).abs() < 0.5) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _gridScroll.jumpTo(offset);
      } else {
        unawaited(
          _gridScroll.animateTo(
            offset,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          ),
        );
      }
    });
  }

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
    _revealPage(toIndex);
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Page moved to position ${toIndex + 1} of ${_pages.length}',
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
          'All pages in this draft will be deleted. '
          'PDFs you already exported are not affected.',
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
      unawaited(
        deleteSharedExportCopies(temporaryDirectory: widget.temporaryDirectory),
      );
      if (!_isPickingImages) {
        unawaited(
          sweepImagePickerCopies(temporaryDirectory: widget.temporaryDirectory),
        );
      }
    }
    setState(() {
      if (cleared) {
        _pages.clear();
        _draftRestoreFailed = false;
        _lastNewPageFilter = PageFilter.original;
        _draftSaveFailed = false;
        _deferredMessage = null;
      }
      _isClearingDraft = false;
    });
    _resumeSharedImageIntake();
  }

  bool get _ocrSupported =>
      widget.searchablePdfEnabled ??
      defaultTargetPlatform == TargetPlatform.android;

  void _updatePdfProgress(int completed, int total) {
    if (mounted) setState(() => _pdfProgress = completed / total);
  }

  Future<void> _createSearchablePdf(List<ScannedPage> pages, File output) {
    return ocr_service.createSearchablePdf(
      [for (final page in pages) page.processedBytes],
      outputPath: output.path,
      pageSize: _preferences.pdfPageSize,
      quality: _preferences.pdfQuality,
      onProgress: _updatePdfProgress,
    );
  }

  Future<bool> _confirmImageOnlyFallback() async {
    if (!mounted) return false;
    final fallback = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Searchable export failed'),
        content: const Text('Export an image-only PDF instead?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Export image-only PDF'),
          ),
        ],
      ),
    );
    return fallback ?? false;
  }

  // Shares by path: the platform reads the file itself, so the PDF never has
  // to be loaded into this isolate. Share targets see the file's own name.
  Future<ShareResult> _sharePdfFile(
    File pdf, {
    required String fileName,
    required Rect? shareOrigin,
  }) {
    return _sharePlus.share(
      ShareParams(
        files: [XFile(pdf.path, name: fileName, mimeType: 'application/pdf')],
        fileNameOverrides: [fileName],
        sharePositionOrigin: shareOrigin,
        downloadFallbackEnabled: true,
      ),
    );
  }

  Future<void> _createImageOnlyPdf(List<ScannedPage> pages, File output) {
    return image_pdf.writeImageOnlyPdf(
      [for (final page in pages) page.processedBytes],
      output.path,
      pageSize: _preferences.pdfPageSize,
      quality: _preferences.pdfQuality,
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
      await ocr_service.cancelOcrJob();
    } catch (error) {
      if (mounted && !ocr_service.isCancellation(error)) {
        _showMessage('Could not cancel the export.');
      }
    }
  }

  /// Writes the PDF into [directory] and returns it, or null when the user
  /// declined the image-only fallback.
  Future<({File file, String name, bool searchable})?> _createPdf(
    List<ScannedPage> pages, {
    required bool useOcr,
    required PdfExportDirectory directory,
    required DateTime now,
  }) async {
    if (useOcr) {
      try {
        final name = pdfExportFileName(now, searchable: true);
        final file = directory.fileNamed(name);
        await _createSearchablePdf(pages, file);
        return (file: file, name: name, searchable: true);
      } catch (error) {
        if (ocr_service.isCancellation(error)) rethrow;
        if (!mounted) return null;
        setState(() => _pdfProgress = null);
        if (!await _confirmImageOnlyFallback()) return null;
      }
    }

    if (!mounted) return null;
    if (useOcr) {
      setState(() {
        // A confirmed fallback starts fresh after an OCR failure.
        _isCancellingPdf = false;
        _pdfExporter = _PdfExporter.imageOnly;
        _pdfProgress = 0;
      });
    }
    final name = pdfExportFileName(now, searchable: false);
    final file = directory.fileNamed(name);
    await _createImageOnlyPdf(pages, file);
    return (file: file, name: name, searchable: false);
  }

  bool get _canSaveToDevice => widget.documentSaver.isSupported;

  Future<void> _generateAndSharePdf() =>
      _generateAndExportPdf(_ExportAction.share);

  Future<void> _generateAndSavePdf() =>
      _generateAndExportPdf(_ExportAction.save);

  Future<void> _generateAndExportPdf(_ExportAction action) async {
    if (!_canExport) return;
    // Drop Undo before exporting so a deleted page cannot consume untracked
    // headroom or be restored by a callback captured before the export lock.
    _undoGeneration++;
    _undoPage = null;
    _deferredMessage = null;
    ScaffoldMessenger.of(context).clearSnackBars();
    final pages = List<ScannedPage>.of(_pages, growable: false);
    final useOcr = _exportsSearchable;
    // Capture the required iPad popover anchor before awaiting worker results.
    final shareOrigin = _shareOrigin;
    final now = DateTime.now();
    // Saving asks for the location first, so cancelling the picker never
    // throws away a finished (possibly OCR'd) document.
    final choosesTarget = action == _ExportAction.save;

    setState(() {
      _isGeneratingPdf = true;
      _isSharingPdf = choosesTarget;
      _saveTargetName = null;
      _exportAction = action;
      _isCancellingPdf = false;
      _pdfExporter = useOcr ? _PdfExporter.searchable : _PdfExporter.imageOnly;
      _pdfProgress = choosesTarget ? null : 0;
    });

    PdfExportDirectory? exportDirectory;
    PdfSaveTarget? saveTarget;
    var saved = false;
    try {
      if (choosesTarget) {
        saveTarget = await widget.documentSaver.chooseTarget(
          fileName: pdfExportFileName(now, searchable: useOcr),
        );
        // A cancelled picker is a silent no-op: nothing was generated.
        if (saveTarget == null || !mounted) return;
        setState(() {
          _saveTargetName = saveTarget!.fileName;
          _isSharingPdf = false;
          _pdfProgress = 0;
        });
      }
      // Popping an editor does not interrupt its active worker. Use the same
      // queue so PDF/OCR processing cannot overlap that native allocation.
      final pdf = await _imageProcessingQueue.run(() async {
        if (!mounted) return null;
        if (_isCancellingPdf) {
          throw const image_pdf.ImagePdfCancelledException();
        }
        exportDirectory = await createPdfExportDirectory(
          temporaryDirectory: widget.temporaryDirectory,
        );
        return _createPdf(
          pages,
          useOcr: useOcr,
          directory: exportDirectory!,
          now: now,
        );
      });
      if (pdf == null || !mounted || _isCancellingPdf) return;
      setState(() {
        _pdfProgress = null;
        _isSharingPdf = true;
      });
      if (action == _ExportAction.share) {
        final shared = await _sharePdfFile(
          pdf.file,
          fileName: pdf.name,
          shareOrigin: shareOrigin,
        );
        // A dismissed sheet handed the copy to nobody. After a successful
        // share the receiving app may still be reading it, so it stays until
        // the next share, Clear all or launch.
        if (shared.status == ShareResultStatus.dismissed) {
          unawaited(
            deleteSharedExportCopies(
              fileName: pdf.name,
              temporaryDirectory: widget.temporaryDirectory,
            ),
          );
        }
      } else {
        var savedName = saveTarget!.fileName;
        // The location was chosen for a searchable PDF. After an image-only
        // fallback, drop the suggested " (searchable)" where the provider
        // can rename; a name the user typed is kept as is.
        if (useOcr && !pdf.searchable) {
          final plainName = withoutSearchableSuffix(savedName);
          if (plainName != null) {
            savedName = await saveTarget.rename(plainName) ?? savedName;
          }
        }
        await saveTarget.write(pdf.file);
        saved = true;
        if (mounted) _showMessage('Saved “$savedName”');
      }
    } catch (error) {
      if (ocr_service.isCancellation(error) ||
          error is image_pdf.ImagePdfCancelledException) {
        if (mounted) _showMessage('Export canceled');
      } else {
        if (kDebugMode) {
          debugPrint('PDF export failed (${error.runtimeType}).');
        }
        if (mounted) {
          _showMessage(
            action == _ExportAction.share
                ? 'Could not export the PDF. Try again.'
                : 'Could not save the PDF. Try again, or choose another '
                      'location.',
          );
        }
      }
    } finally {
      // Sharing and saving return once the platform has taken its own copy
      // (or failed), so the exported file is no longer needed. Files orphaned
      // by a killed process are swept at the next launch.
      exportDirectory?.delete();
      // The picker already created an empty document; remove it when the
      // export was cancelled, declined or failed.
      if (saveTarget != null && !saved) unawaited(saveTarget.discard());
      if (mounted) {
        setState(() {
          _isGeneratingPdf = false;
          _isSharingPdf = false;
          _saveTargetName = null;
          _isCancellingPdf = false;
          _pdfExporter = null;
          _pdfProgress = null;
        });
      }
      _resumeSharedImageIntake();
    }
  }

  /// Recognizes the text of every page on device and copies it to the
  /// clipboard. Runs as an export job: it holds the same document lock, shows
  /// its progress in the export bar and can be cancelled there.
  Future<void> _copyRecognizedText() async {
    if (!_canExport || !_ocrSupported) return;
    _undoGeneration++;
    _undoPage = null;
    _deferredMessage = null;
    ScaffoldMessenger.of(context).clearSnackBars();
    final pages = [for (final page in _pages) page.processedBytes];
    setState(() {
      _isGeneratingPdf = true;
      _isSharingPdf = false;
      _exportAction = _ExportAction.copyText;
      _isCancellingPdf = false;
      _pdfExporter = _PdfExporter.searchable;
      _pdfProgress = 0;
    });
    try {
      final copied = await _imageProcessingQueue.run(() {
        if (_isCancellingPdf) {
          throw const image_pdf.ImagePdfCancelledException();
        }
        return ocr_service.copyRecognizedText(
          pages,
          onProgress: _updatePdfProgress,
        );
      });
      if (mounted) _showMessage(copied > 0 ? 'Text copied' : 'No text found');
    } catch (error) {
      final cancelled =
          ocr_service.isCancellation(error) ||
          error is image_pdf.ImagePdfCancelledException;
      if (!cancelled && kDebugMode) {
        debugPrint('Text recognition failed (${error.runtimeType}).');
      }
      if (mounted) {
        _showMessage(
          cancelled ? 'Text recognition canceled' : 'Could not recognize text.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPdf = false;
          _isCancellingPdf = false;
          _pdfExporter = null;
          _pdfProgress = null;
        });
      }
      _resumeSharedImageIntake();
    }
  }

  Future<void> _showExportOptions() async {
    if (!_canExport) return;
    // Every control re-checks that the sheet still belongs to an idle screen,
    // so a stale callback cannot change settings during an export.
    bool canChange(BuildContext sheetContext) =>
        mounted && _canExport && sheetContext.mounted;
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
                if (_ocrSupported) ...[
                  const SizedBox(height: 8),
                  // One subtitle for both states: the switch and the summary's
                  // semantics value carry on/off, and a changing line count
                  // would move the switch under the finger.
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Searchable text'),
                    subtitle: const Text('Search and copy text in the PDF.'),
                    value: _preferences.searchablePdf,
                    onChanged: (value) {
                      if (!canChange(sheetContext)) return;
                      _updatePreferences(
                        _preferences.copyWith(searchablePdf: value),
                      );
                      updateSheet(() {});
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.content_copy_outlined),
                    title: const Text('Copy text'),
                    onTap: () {
                      if (!canChange(sheetContext)) return;
                      Navigator.of(sheetContext).pop();
                      unawaited(_copyRecognizedText());
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Supports Latin-script text. Runs on your device.',
                  ),
                ],
                const SizedBox(height: 16),
                _buildOptionChoices<PdfPageSize>(
                  title: 'Page size',
                  values: PdfPageSize.values,
                  selected: _preferences.pdfPageSize,
                  label: (size) => size.label,
                  onSelected: (size) {
                    if (!canChange(sheetContext)) return;
                    _updatePreferences(
                      _preferences.copyWith(pdfPageSize: size),
                    );
                    updateSheet(() {});
                  },
                ),
                const SizedBox(height: 16),
                _buildOptionChoices<PdfQuality>(
                  title: 'Quality',
                  values: PdfQuality.values,
                  selected: _preferences.pdfQuality,
                  label: (quality) => quality.label,
                  onSelected: (quality) {
                    if (!canChange(sheetContext)) return;
                    _updatePreferences(
                      _preferences.copyWith(pdfQuality: quality),
                    );
                    updateSheet(() {});
                  },
                ),
                const SizedBox(height: 8),
                // Sized to the longest description so choosing a quality
                // never resizes the bottom-anchored sheet.
                IndexedStack(
                  index: PdfQuality.values.indexOf(_preferences.pdfQuality),
                  children: [
                    for (final quality in PdfQuality.values)
                      Text(switch (quality) {
                        PdfQuality.high => 'Full resolution. Largest files.',
                        PdfQuality.balanced =>
                          'Up to 200 DPI with moderate compression. Much '
                              'smaller files that print well.',
                        PdfQuality.small =>
                          'Up to 150 DPI with strong compression, for email '
                              'and upload limits. Fine print may lose detail.',
                      }),
                  ],
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

  // Chips wrap onto new lines at large text sizes instead of overflowing.
  Widget _buildOptionChoices<T>({
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T value) label,
    required void Function(T value) onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in values)
              // No checkmark: it would widen the selected chip and could
              // re-wrap the row, moving chips and the sheet edge.
              ChoiceChip(
                showCheckmark: false,
                label: Text(label(value)),
                selected: value == selected,
                onSelected: (_) => onSelected(value),
              ),
          ],
        ),
      ],
    );
  }

  String get _exportStatus {
    if (_isClearingDraft) return 'Clearing draft…';
    if (_exportAction == _ExportAction.copyText) {
      if (_isCancellingPdf) return 'Canceling…';
      if (_pdfProgress == null) return 'Recognizing text…';
      return 'Recognizing text ${(_pdfProgress! * 100).round()}%';
    }
    if (_isCancellingPdf) return 'Canceling…';
    if (_isSharingPdf) {
      if (_exportAction != _ExportAction.save) return 'Opening share sheet…';
      return _saveTargetName == null ? 'Choose where to save…' : 'Saving PDF…';
    }
    if (_pdfProgress == null) return 'Preparing PDF…';
    final percent = (_pdfProgress! * 100).round();
    // The searchable renderer reports pages as Tesseract finishes them.
    return _pdfExporter == _PdfExporter.searchable
        ? 'Recognizing text $percent%'
        : 'Generating PDF $percent%';
  }

  String get _exportOptionsSummary => [
    if (_ocrSupported)
      _exportsSearchable ? 'Searchable text on' : 'Searchable text off',
    '${_preferences.pdfPageSize.label} page size',
    '${_preferences.pdfQuality.label} quality',
  ].join(', ');

  /// The page count comes right after the verb, so it stays visible when a
  /// large text size truncates the label.
  String get _exportLabel {
    final pages = '${_pages.length} ${_pages.length == 1 ? 'page' : 'pages'}';
    return _exportsSearchable
        ? 'Export $pages as searchable PDF'
        : 'Export $pages as PDF';
  }

  /// One height for every export state and page count, so starting,
  /// progressing or finishing an export never shifts the page grid or the
  /// camera button. It reserves two lines of the label style at the user's
  /// text size, so a label or status that wraps at large text still fits;
  /// at the default size this is the standard 56 px.
  double _exportBarHeight(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 14) *
        (style?.height ?? 1.43);
    return math.max(56, 2 * lineHeight + 8);
  }

  /// Whether the Cancel button in the busy bar responds. Its slot stays for
  /// the whole job so the status text never changes width.
  bool get _canCancelExport =>
      _isGeneratingPdf &&
      !_isCancellingPdf &&
      !_isSharingPdf &&
      _pdfProgress != null;

  Widget _buildExportBar() {
    final busy = _isGeneratingPdf || _isClearingDraft;
    final height = _exportBarHeight(context);
    return SafeArea(
      key: const Key('pdf_export_bar'),
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SizedBox(
          height: height,
          child: Row(
            children: busy
                ? [
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
                        child: Text(
                          _exportStatus,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (_isGeneratingPdf)
                      TextButton(
                        onPressed: _canCancelExport
                            ? _cancelPdfGeneration
                            : null,
                        child: const Text('Cancel'),
                      ),
                  ]
                : [
                    Expanded(
                      child: FilledButton.icon(
                        key: _shareButtonKey,
                        style: FilledButton.styleFrom(
                          minimumSize: Size.fromHeight(height),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onPressed: _canExport ? _generateAndSharePdf : null,
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        // Up to two lines fit the reserved bar height;
                        // longer labels truncate and semantics keep them.
                        label: Text(
                          _exportLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // Android only: the iOS share sheet already offers
                    // "Save to Files".
                    if (_canSaveToDevice) ...[
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: _canExport ? _generateAndSavePdf : null,
                        tooltip: 'Save PDF to device',
                        icon: const Icon(Icons.save_alt_outlined),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Semantics(
                      value: _exportOptionsSummary,
                      child: IconButton.filledTonal(
                        onPressed: _canExport ? _showExportOptions : null,
                        tooltip: 'PDF export options',
                        icon: const Icon(Icons.tune_outlined),
                      ),
                    ),
                  ],
          ),
        ),
      ),
    );
  }

  /// Height of the export bar (plus its 8 px vertical padding), excluding the
  /// bottom safe area. The camera button floats above this space even while
  /// the bar is absent, so adding the first page never moves it.
  double _reservedExportBarHeight(BuildContext context) =>
      _exportBarHeight(context) + 16;

  /// Holds the export bar's space while there are no pages, so the page
  /// area, the camera button and snackbars keep their positions when the
  /// first page is added or the last one removed.
  Widget _buildExportBarSpace(BuildContext context) => SafeArea(
    key: const Key('export_bar_space'),
    top: false,
    child: SizedBox(height: _reservedExportBarHeight(context)),
  );

  bool get _canClearPages =>
      _pages.isNotEmpty && !_isClearingDraft && !_isGeneratingPdf;

  static const _draftHint =
      'Drafts are temporary. Export a PDF to keep a copy.';

  /// How many lines [text] takes at [maxWidth], at most [maxLines].
  static int _lineCount(
    String text, {
    required TextStyle? style,
    required TextScaler textScaler,
    required double maxWidth,
    required int maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: maxLines,
    )..layout(maxWidth: math.max(0, maxWidth));
    final lines = painter.computeLineMetrics().length;
    painter.dispose();
    return lines.clamp(1, maxLines);
  }

  static const _draftSaveFailureMessage =
      'Could not save the latest draft changes. Keep the app open and retry.';

  /// One fixed-height slot above the pages that shows either the draft hint
  /// or a draft-save failure with Retry. A failure arrives asynchronously, so
  /// it must replace the hint in place instead of pushing the grid down.
  ///
  /// On tall screens it fits two lines of the hint at the user's text size,
  /// so large text wraps the hint instead of cutting it off early.
  /// Short landscape screens keep one line for the pages. The height depends
  /// only on the screen and the text size, never on the state.
  /// Image intake help shares the line, so it never moves the grid either.
  Widget _buildDraftStatusSlot(BuildContext context) {
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final screen = MediaQuery.sizeOf(context);
    final style = theme.textTheme.bodySmall;
    final hintLines = screen.height < 480
        ? 1
        : _lineCount(
            _draftHint,
            style: style,
            textScaler: textScaler,
            maxWidth: screen.width - 32,
            maxLines: 2,
          );
    final lineHeight =
        textScaler.scale(style?.fontSize ?? 12) * (style?.height ?? 1.33);
    final height = math.max(
      48.0,
      math.max(textScaler.scale(20), hintLines * lineHeight) + 8,
    );
    final Widget content;
    if (_draftSaveFailed) {
      final errorColor = theme.colorScheme.error;
      content = Row(
        children: [
          Icon(Icons.error_outline, color: errorColor),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              liveRegion: true,
              label: _draftSaveFailureMessage,
              excludeSemantics: true,
              child: Tooltip(
                message: _draftSaveFailureMessage,
                triggerMode: TooltipTriggerMode.tap,
                child: Text(
                  'Draft not saved',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: errorColor,
                  ),
                ),
              ),
            ),
          ),
          TextButton(
            key: const Key('retry_draft_save'),
            onPressed: _isDraftSaveScheduled || _isClearingDraft
                ? null
                : _queueDraftSave,
            child: const Text('Retry', maxLines: 1),
          ),
        ],
      );
    } else {
      final help = _imageIntakeStatus == null
          ? null
          : TextButton.icon(
              onPressed: _showImageIntakeStatus,
              icon: const Icon(Icons.info_outline),
              label: const Text('Image intake help', maxLines: 1),
            );
      content = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_pages.isNotEmpty)
            Expanded(
              child: Text(
                _draftHint,
                style: style,
                textAlign: TextAlign.center,
                maxLines: hintLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (help != null) Flexible(child: help),
        ],
      );
    }
    return SizedBox(
      key: const Key('draft_status_slot'),
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Center(child: content),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    // Nominal height of the ready state (icon, one-line title, two lines of
    // copy and the gallery button). The top inset centers that block, but
    // depends only on the viewport: the restoring and ready states start at
    // the same place, so the icon and title never move between them.
    final readyHeight =
        80 + 16 + textScaler.scale(32) + 8 + textScaler.scale(40) + 24 + 48;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The space the page grid keeps free for the camera button is
        // scroll padding here: the content centers above the button and can
        // always be scrolled clear of it.
        final geometry = _pageGridGeometry(constraints.biggest);
        final besideCamera = geometry.padding.end > _pageGridSpacing
            ? geometry.padding.end
            : 0.0;
        final height = constraints.maxHeight - geometry.cameraInset;
        return _buildEmptyStateContent(
          context,
          padding: EdgeInsetsDirectional.fromSTEB(
            32,
            math.max(32, (height - readyHeight) / 2),
            math.max(32, besideCamera),
            32 + geometry.cameraInset,
          ),
        );
      },
    );
  }

  Widget _buildEmptyStateContent(
    BuildContext context, {
    required EdgeInsetsDirectional padding,
  }) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SingleChildScrollView(
      padding: padding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The spinner gets the icon's 80 px square.
              Center(
                child: SizedBox.square(
                  key: const Key('empty_state_icon'),
                  dimension: 80,
                  child: _isRestoringDraft
                      ? const Center(child: CircularProgressIndicator())
                      : Icon(
                          _cameraSupported
                              ? Icons.camera_alt_outlined
                              : Icons.photo_library_outlined,
                          size: 80,
                          color: muted,
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isRestoringDraft ? 'Restoring draft…' : 'Ready to scan',
                key: const Key('empty_state_title'),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              if (!_isRestoringDraft) ...[
                const SizedBox(height: 8),
                Text(
                  _cameraSupported
                      ? 'Scan your first page, or import from your gallery.'
                      : 'Import from your gallery to add your first page.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 24),
                Center(
                  child: OutlinedButton.icon(
                    onPressed:
                        _isPickingImages ||
                            _isClearingDraft ||
                            !_canStartImagePick
                        ? null
                        : _importFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Import from gallery'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Lays out the page grid for [viewport] so that at least one whole row of
  /// cards is visible and the camera button never covers a card's controls.
  ///
  /// The result depends only on the viewport and on whether the camera is
  /// available, never on the page count, so cards keep their size as pages
  /// are added or removed.
  _PageGridGeometry _pageGridGeometry(Size viewport) {
    final clearance = _cameraSupported
        ? _cameraButtonClearance
        : _pageGridSpacing;
    ({int columns, double width}) columnsFor(double extent) {
      final columns = math.max(
        1,
        (extent / (_maxPageCardExtent + _pageGridSpacing)).ceil(),
      );
      return (
        columns: columns,
        width: (extent - _pageGridSpacing * (columns - 1)) / columns,
      );
    }

    // Tall viewports: cards keep their shape, and the grid ends above the
    // camera button, so no card scrolls under it.
    final tall = columnsFor(viewport.width - 2 * _pageGridSpacing);
    final tallHeight = tall.width / _pageCardAspectRatio;
    final cameraInset = _cameraSupported ? _cameraButtonClearance : 0.0;
    if (2 * _pageGridSpacing + tallHeight + cameraInset <= viewport.height) {
      return (
        columns: tall.columns,
        cardSize: Size(tall.width, tallHeight),
        padding: const EdgeInsetsDirectional.all(_pageGridSpacing),
        cameraInset: cameraInset,
      );
    }
    // Short viewports (landscape phones): cards are shortened so a whole row
    // fits, and the grid leaves a column for the camera button, which would
    // otherwise cover the end card of every row. The vertical padding
    // halves, which keeps a usable thumbnail at the largest text size.
    const vertical = _pageGridSpacing / 2;
    final short = columnsFor(viewport.width - _pageGridSpacing - clearance);
    final shortHeight = math.max(
      _minPageCardHeight,
      math.min(
        short.width / _pageCardAspectRatio,
        viewport.height - 2 * vertical,
      ),
    );
    return (
      columns: short.columns,
      cardSize: Size(short.width, shortHeight),
      padding: EdgeInsetsDirectional.fromSTEB(
        _pageGridSpacing,
        vertical,
        clearance,
        vertical,
      ),
      cameraInset: 0,
    );
  }

  Widget _buildPageGrid() => LayoutBuilder(
    builder: (context, constraints) {
      final geometry = _gridGeometry = _pageGridGeometry(constraints.biggest);
      return Padding(
        padding: EdgeInsets.only(bottom: geometry.cameraInset),
        child: GridView.builder(
          key: const Key('page_grid'),
          controller: _gridScroll,
          padding: geometry.padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: geometry.columns,
            crossAxisSpacing: _pageGridSpacing,
            mainAxisSpacing: _pageGridSpacing,
            mainAxisExtent: geometry.cardSize.height,
          ),
          itemCount: _pages.length,
          itemBuilder: (context, index) =>
              _buildPageCard(context, index, geometry.cardSize),
        ),
      );
    },
  );

  Widget _buildPageCard(BuildContext context, int index, Size cardSize) {
    final page = _pages[index];
    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _isDocumentInteractionLocked ? null : () => _openPage(index),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                key: ValueKey('page_thumbnail_$index'),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
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
            // Every footer has the same controls and a one-line label, so
            // thumbnails keep one size for any page count or page number.
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: ExcludeSemantics(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          'Page ${index + 1}',
                          maxLines: 1,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    ),
                  ),
                  _pageReorderMenu(index, page),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete page ${index + 1}',
                    onPressed: _isDocumentInteractionLocked
                        ? null
                        : () => _removePage(index),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Drag-to-reorder remains available alongside equivalent semantic
    // actions for switch and screen-reader users.
    final reorderActions = <CustomSemanticsAction, VoidCallback>{
      if (!_isDocumentInteractionLocked && index > 0)
        const CustomSemanticsAction(label: 'Move earlier'): () =>
            _reorderPage(index, index - 1),
      if (!_isDocumentInteractionLocked && index < _pages.length - 1)
        const CustomSemanticsAction(label: 'Move later'): () =>
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
            !_isDocumentInteractionLocked && details.data != index,
        onAcceptWithDetails: (details) => _reorderPage(details.data, index),
        builder: (context, candidateData, rejectedData) {
          final isDropTarget = candidateData.isNotEmpty;
          return LongPressDraggable<int>(
            data: index,
            maxSimultaneousDrags: _isDocumentInteractionLocked ? 0 : 1,
            // The dragged copy has the card's own size, so its label and
            // controls are laid out exactly as on the card.
            feedback: SizedBox.fromSize(
              key: const Key('page_drag_feedback'),
              size: cardSize,
              child: Material(
                color: Colors.transparent,
                child: Opacity(opacity: 0.85, child: card),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.3, child: card),
            // The highlight is painted over the card instead of padding it,
            // so the hovered card keeps its size.
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: isDropTarget
                  ? BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    )
                  : const BoxDecoration(),
              child: card,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_draftRestoreFailed) return _buildDraftRestoreFailure();
    // System Back must not finish the activity and silently drop a running
    // export or text copy; the visible Cancel is the way out.
    return PopScope(canPop: !_isGeneratingPdf, child: _buildScaffold(context));
  }

  Widget _buildScaffold(BuildContext context) {
    _fabLocation.estimatedBarHeight = _reservedExportBarHeight(context);
    return Scaffold(
      appBar: AppBar(
        // Scales down rather than truncating at large text sizes.
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text('FOSScanner'),
        ),
        // The same actions in the same places whether or not the document has
        // pages; clearing lives in the always-present overflow menu.
        actions: [
          if (supportsBarcodeCamera(
            platform: defaultTargetPlatform,
            isWeb: kIsWeb,
          ))
            IconButton(
              icon: const Icon(Icons.qr_code_scanner_outlined),
              onPressed: _isRestoringDraft || _isDocumentInteractionLocked
                  ? null
                  : _openBarcodeScanner,
              tooltip: 'Scan QR code or barcode',
            ),
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            onPressed:
                _isPickingImages || _isClearingDraft || !_canStartImagePick
                ? null
                : _importFromGallery,
            tooltip: 'Import from gallery',
          ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            onSelected: _onOverflowSelected,
            itemBuilder: (_) => [
              ..._pdfImportMenuItems(),
              PopupMenuItem(
                value: 'clear',
                enabled: _canClearPages,
                child: ListTile(
                  enabled: _canClearPages,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('Clear all pages'),
                ),
              ),
              ...screenPrivacyMenuItems(
                supported: screen_privacy.isSecureScreenSupported,
                blockScreenshots: _preferences.blockScreenshots,
              ),
              const PopupMenuItem(
                value: 'about',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.info_outline),
                  title: Text('About FOSScanner'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildDraftStatusSlot(context),
          Expanded(
            child: _pages.isEmpty
                ? _buildEmptyState(context)
                : _buildPageGrid(),
          ),
        ],
      ),
      floatingActionButton: _cameraSupported
          ? FloatingActionButton(
              onPressed:
                  _isPickingImages || _isClearingDraft || !_canStartImagePick
                  ? null
                  : _captureImage,
              tooltip: 'Scan a page',
              child: const Icon(Icons.camera_alt_outlined),
            )
          : null,
      floatingActionButtonLocation: _fabLocation,
      bottomNavigationBar: _pages.isEmpty
          ? _buildExportBarSpace(context)
          : _buildExportBar(),
    );
  }
}
