import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, listEquals;
import 'package:flutter/material.dart';

import '../models/scanned_page.dart';
import '../services/adjustment_scale.dart';
import '../services/corner_adjust_operations.dart';
import '../services/corner_geometry.dart';
import '../services/gesture_exclusion.dart';
import '../services/image_processing_queue.dart';
import '../widgets/corner_overlay.dart';
import '../widgets/transient_message.dart';

export '../services/corner_adjust_operations.dart';
export '../services/image_processing_queue.dart';

const _fullPreviewDecodeSize = 2048;
const _filterChipDecodeSize = 256;

class _QueuedWorkResult<T> {
  const _QueuedWorkResult.started(this.value) : started = true;
  const _QueuedWorkResult.skipped() : started = false, value = null;

  final bool started;
  final T? value;
}

const _filterLabels = {
  PageFilter.original: 'Original',
  PageFilter.autoEnhance: 'Enhance',
  PageFilter.grayscale: 'Grayscale',
  PageFilter.blackAndWhite: 'Black & white',
};

/// The original picker source may be unknown after Android activity recovery.
/// [shared] images were sent from another app and copied into app storage.
enum PageReviewSource {
  camera,
  gallery,
  recovered,
  shared,

  /// A page rendered from an imported PDF.
  pdf,
}

/// A review's crop and appearance, handed to [CornerAdjustScreen.onRetake]
/// so that cancelling the camera can reopen the review exactly as it was.
class PageReviewState {
  const PageReviewState({
    required this.corners,
    required this.startCorners,
    required this.filter,
    required this.rotationQuarterTurns,
    required this.brightness,
    required this.contrast,
  });

  final List<Offset> corners;

  /// The detected (or full-image) corners a double-tap restores.
  final List<Offset> startCorners;
  final PageFilter filter;
  final int rotationQuarterTurns;
  final double brightness;
  final double contrast;
}

enum _Step { corners, filter }

/// What leaving the review from the crop step would lose, and so which
/// question Back and Cancel ask first.
enum _LeaveConfirmation {
  /// Edits to a page that is kept as it was.
  discardChanges,

  /// A new camera capture, edited or not.
  discardScan,

  /// The rest of a batch import, and any edits to this image.
  stopImport,
}

/// Appearance controls shown in the landscape side column.
enum _Panel { filters, adjust }

enum _PreviewStatus { pending, updating, ready, failed }

/// Post-capture review, in two steps:
///
/// 1. Adjust corners on the raw photo (pre-filled from auto-detection when
///    possible).
/// 2. A full-size preview of the perspective-corrected page with the
///    selected filter actually applied — not just a small chip thumbnail —
///    so the user sees what they're about to save before confirming.
///
/// Also used for re-editing, in which case [initialCorners] is the
/// page's previously saved corners rather than a fresh detection.
class CornerAdjustScreen extends StatefulWidget {
  const CornerAdjustScreen({
    super.key,
    required this.originalBytes,
    this.source,
    this.isBatchImport = false,
    this.batchPosition,
    this.batchCount,
    this.onStopImport,
    this.onScanNext,
    this.onRetake,
    this.onUnreadable,
    this.restoredReview,
    this.initialCorners,
    this.startWithAdjustments = false,
    this.detectPageEdges = true,
    this.initialFilter = PageFilter.original,
    this.initialRotationQuarterTurns = 0,
    this.initialBrightness = 0.0,
    this.initialContrast = 1.0,
    this.operations = const DefaultCornerAdjustOperations(),
    this.processingQueue,
  });

  final Uint8List originalBytes;

  /// Null for existing-page editing or callers without intake provenance.
  final PageReviewSource? source;

  /// Refers to the original selection, including its final image.
  final bool isBatchImport;

  /// One-based position of this image within a batch import, and the batch
  /// size. Both are null outside batch review.
  final int? batchPosition;
  final int? batchCount;

  /// Called before this route closes when the user stops a batch import.
  /// The current and remaining images are not added; accepted pages stay.
  final VoidCallback? onStopImport;

  /// Continuous camera capture. When set for a new camera capture, the
  /// appearance step offers **Add & scan next** next to **Add page**; this is
  /// called just before the route pops with the accepted page so the caller
  /// can relaunch the camera. The route result stays a [ScannedPage], so
  /// callers that do not opt in are unaffected.
  final VoidCallback? onScanNext;

  /// When set for a new camera capture, the crop step's **Cancel** becomes
  /// **Retake**: this is called with the review's current crop and settings
  /// before the route pops without a page, so the caller can relaunch the
  /// camera and, if it is cancelled, reopen this review via
  /// [restoredReview].
  final ValueChanged<PageReviewState>? onRetake;

  /// Called when [originalBytes] cannot be decoded. The review then only
  /// offers Go back and closes without a page, so callers can report the
  /// image as unreadable instead of skipped. Leaving it never stops a batch.
  final VoidCallback? onUnreadable;

  /// Reopens a review left with Retake: its corners and settings replace
  /// edge detection and the initial settings. Still a new page.
  final PageReviewState? restoredReview;
  final List<Offset>? initialCorners;

  /// Open saved appearance directly; crop remains available.
  final bool startWithAdjustments;

  /// When false, a new page starts as a full-image crop without running
  /// edge detection, for sources that are already flat pages (PDF imports).
  final bool detectPageEdges;
  final PageFilter initialFilter;
  final int initialRotationQuarterTurns;
  final double initialBrightness;
  final double initialContrast;
  final CornerAdjustOperations operations;
  final ImageProcessingQueue? processingQueue;

  @override
  State<CornerAdjustScreen> createState() => _CornerAdjustScreenState();
}

class _CornerAdjustScreenState extends State<CornerAdjustScreen> {
  Size? _imageSize;
  List<Offset>? _corners;
  // Detected, saved or full-image corners: what a double-tap restores.
  List<Offset>? _startCorners;
  CropProblem? _cropProblem;
  bool _showFullImageNotice = false;
  // Kept in the tree while the notice fades out after the first adjustment.
  bool _fullImageNoticeMounted = false;
  bool _isProcessing = false;
  bool _isLeaving = false;
  bool _isScanNextRequested = false;
  String? _error;
  late final ImageProcessingQueue _processingQueue;
  int _initializationGeneration = 0;
  int _exportGeneration = 0;

  _Step _step = _Step.corners;
  LocalHistoryEntry? _filterHistoryEntry;
  // Side by side (landscape), Filters and Adjust open in the control column
  // rather than as bottom sheets, so the preview stays fully visible. Back
  // closes the panel first, like a sheet.
  _Panel? _sidePanel;
  LocalHistoryEntry? _panelHistoryEntry;
  bool _isSideBySide = false;
  late PageFilter _selectedFilter =
      widget.restoredReview?.filter ?? widget.initialFilter;
  late int _rotationQuarterTurns =
      widget.restoredReview?.rotationQuarterTurns ??
      widget.initialRotationQuarterTurns;
  late double _brightness =
      widget.restoredReview?.brightness ?? widget.initialBrightness;
  late double _contrast =
      widget.restoredReview?.contrast ?? widget.initialContrast;
  // Cache reduced-resolution filter previews so dragging only reprocesses on
  // drag-end. Confirm deliberately recomputes the selected filter at the full
  // bounded export resolution.
  Map<PageFilter, Uint8List>? _filterPreviews;
  bool _isGeneratingPreviews = false;
  int _previewGeneration = 0;
  // Rotation + brightness/contrast applied on top of _filterPreviews[
  // _selectedFilter], recomputed on rotate/slider-release/filter-change
  // rather than baked into _filterPreviews (which only need to answer
  // "what does each filter choice look like", not track these extras).
  // Retain the last successful result; status, not the presence of bytes,
  // determines whether the current settings can safely be confirmed.
  Uint8List? _finalPreviewBytes;
  _PreviewStatus _previewStatus = _PreviewStatus.pending;
  int _finalPreviewGeneration = 0;

  @override
  void initState() {
    super.initState();
    _processingQueue = widget.processingQueue ?? ImageProcessingQueue();
    _initialize();
  }

  Future<_QueuedWorkResult<T>> _enqueueWork<T>({
    required bool Function() canStart,
    required Future<T> Function() work,
  }) {
    return _processingQueue.run(() async {
      if (!canStart()) return _QueuedWorkResult<T>.skipped();
      return _QueuedWorkResult<T>.started(await work());
    });
  }

  Future<void> _initialize() async {
    final generation = ++_initializationGeneration;
    try {
      final size = await widget.operations.decodeSize(widget.originalBytes);

      final restored = widget.restoredReview;
      if (restored != null) {
        // Exactly as it was left, problems included: nothing to detect.
        if (!mounted) return;
        setState(() {
          _imageSize = size;
          _corners = List.of(restored.corners);
          _startCorners = List.of(restored.startCorners);
          _cropProblem = cropProblem(_corners!);
        });
        unawaited(_updatePreviews());
        return;
      }

      List<Offset>? candidateCorners = widget.initialCorners;
      if (candidateCorners == null && widget.detectPageEdges) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || generation != _initializationGeneration) return;
        final detection = await _enqueueWork<List<Offset>?>(
          canStart: () => mounted && generation == _initializationGeneration,
          work: () => widget.operations.detectCorners(widget.originalBytes),
        );
        if (!detection.started) return;
        candidateCorners = detection.value;
      }
      final hasCorners = _hasRenderableCorners(candidateCorners);
      final corners = hasCorners
          ? sortCornersIfConvex([
              // Match the overlay's clamping so that it never reports a
              // change the user did not make.
              for (final corner in candidateCorners!)
                Offset(
                  corner.dx.clamp(0.0, size.width - 1),
                  corner.dy.clamp(0.0, size.height - 1),
                ),
            ])
          : _fullBoundsCorners(size);

      if (!mounted) return;
      setState(() {
        _imageSize = size;
        _corners = corners;
        _startCorners = corners;
        _cropProblem = cropProblem(corners);
        // Only a failed detection needs explaining.
        _showFullImageNotice = !hasCorners && widget.detectPageEdges;
        _fullImageNoticeMounted = _showFullImageNotice;
      });
      if (widget.startWithAdjustments && hasCorners) _enterFilterStep();
      unawaited(_updatePreviews());
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Corner initialization failed (${error.runtimeType}).');
      }
      if (!mounted) return;
      setState(() {
        _error = 'Could not read this image.';
      });
      widget.onUnreadable?.call();
    }
  }

  @override
  void dispose() {
    _initializationGeneration++;
    _previewGeneration++;
    _finalPreviewGeneration++;
    _exportGeneration++;
    super.dispose();
  }

  bool _hasRenderableCorners(List<Offset>? corners) =>
      corners != null &&
      corners.length == 4 &&
      corners.toSet().length == 4 &&
      corners.every((corner) => corner.dx.isFinite && corner.dy.isFinite);

  List<Offset> _fullBoundsCorners(Size size) {
    final right = size.width - 1;
    final bottom = size.height - 1;
    return [
      Offset.zero,
      Offset(right, 0),
      Offset(right, bottom),
      Offset(0, bottom),
    ];
  }

  void _showError(String message) => showTransientMessage(context, message);

  Future<void> _updatePreviews() async {
    final currentCorners = _corners;
    if (currentCorners == null || !mounted) return;
    final corners = List<Offset>.of(currentCorners);
    final generation = ++_previewGeneration;
    _finalPreviewGeneration++;
    setState(() {
      _isGeneratingPreviews = true;
      _previewStatus = _PreviewStatus.pending;
      _filterPreviews = null;
    });

    // Do not let an immediately completing worker erase the progress state
    // before Flutter has painted it once.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _previewGeneration) return;

    // Geometry problems are explained in place on the canvas, where the
    // user can fix them; only decoder/backend failures need a message.
    final problem = cropProblem(corners);
    if (problem != null) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _isGeneratingPreviews = false;
        _cropProblem = problem;
      });
      return;
    }

    try {
      final queuedPreviews = await _enqueueWork<Map<PageFilter, Uint8List>>(
        canStart: () => mounted && generation == _previewGeneration,
        work: () =>
            widget.operations.buildPreviews(widget.originalBytes, corners),
      );
      if (!queuedPreviews.started ||
          !mounted ||
          generation != _previewGeneration) {
        return;
      }
      setState(() {
        _filterPreviews = queuedPreviews.value!;
        _isGeneratingPreviews = false;
      });
      unawaited(_updateFinalPreview());
    } catch (_) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() => _isGeneratingPreviews = false);
      _showError('Could not process this image. Try another one.');
    }
  }

  /// Applies the current rotation + brightness/contrast on top of the
  /// selected filter's cached preview. This still decodes and transforms an
  /// image, so the default operations run it outside the UI isolate.
  Future<void> _updateFinalPreview() async {
    if (!mounted || _isProcessing) return;
    final base = _filterPreviews?[_selectedFilter];
    final rotationQuarterTurns = _rotationQuarterTurns;
    final brightness = _brightness;
    final contrast = _contrast;
    final generation = ++_finalPreviewGeneration;
    setState(() {
      _previewStatus = base == null
          ? _PreviewStatus.failed
          : _PreviewStatus.updating;
    });
    if (base == null) return;

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _finalPreviewGeneration) return;

    try {
      final queuedPreview = await _enqueueWork<Uint8List>(
        canStart: () => mounted && generation == _finalPreviewGeneration,
        work: () => widget.operations.buildFinalPreview(
          base,
          rotationQuarterTurns: rotationQuarterTurns,
          brightness: brightness,
          contrast: contrast,
        ),
      );
      if (!queuedPreview.started ||
          !mounted ||
          generation != _finalPreviewGeneration) {
        return;
      }
      setState(() {
        _finalPreviewBytes = queuedPreview.value!;
        _previewStatus = _PreviewStatus.ready;
      });
    } catch (_) {
      if (!mounted || generation != _finalPreviewGeneration) return;
      setState(() => _previewStatus = _PreviewStatus.failed);
    }
  }

  Future<void> _goToFilterStep() async {
    if (!mounted || _isLeaving || _isProcessing || _cropProblem != null) {
      return;
    }
    if (_filterPreviews == null) {
      await _updatePreviews();
      if (!mounted || _isLeaving || _filterPreviews == null) return;
    }
    _enterFilterStep();
  }

  void _enterFilterStep() {
    setState(() => _step = _Step.filter);
    if (_filterHistoryEntry != null) return;
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      onRemove: () {
        if (identical(_filterHistoryEntry, entry)) {
          _filterHistoryEntry = null;
        }
        if (mounted && _step == _Step.filter) {
          setState(() => _step = _Step.corners);
        }
      },
    );
    _filterHistoryEntry = entry;
    ModalRoute.of(context)?.addLocalHistoryEntry(entry);
  }

  bool get _canConfirm =>
      _step == _Step.filter &&
      !_isProcessing &&
      !_isGeneratingPreviews &&
      _previewStatus == _PreviewStatus.ready &&
      _finalPreviewBytes != null;

  Future<void> _confirm({bool scanNext = false}) async {
    final corners = _corners;
    if (corners == null || !_canConfirm) return;
    if (scanNext && !_canScanNext) return;
    final filter = _selectedFilter;
    final rotationQuarterTurns = _rotationQuarterTurns;
    final brightness = _brightness;
    final contrast = _contrast;
    _previewGeneration++;
    _finalPreviewGeneration++;
    final exportGeneration = ++_exportGeneration;
    setState(() {
      _isProcessing = true;
      _isScanNextRequested = scanNext;
      _isGeneratingPreviews = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      final queuedExport = await _enqueueWork<Uint8List>(
        canStart: () => mounted && exportGeneration == _exportGeneration,
        work: () => widget.operations.processForExport(
          widget.originalBytes,
          corners,
          filter: filter,
          rotationQuarterTurns: rotationQuarterTurns,
          brightness: brightness,
          contrast: contrast,
        ),
      );
      if (!queuedExport.started || !mounted) return;
      final page = ScannedPage(
        originalBytes: widget.originalBytes,
        corners: corners,
        filter: filter,
        rotationQuarterTurns: rotationQuarterTurns,
        brightness: brightness,
        contrast: contrast,
        processedBytes: queuedExport.value!,
      );
      // Otherwise Navigator.pop would consume the local filter history entry
      // instead of completing this route with the scanned page.
      _panelHistoryEntry?.remove();
      _filterHistoryEntry?.remove();
      if (!mounted) return;
      if (scanNext) widget.onScanNext!();
      Navigator.of(context).pop(page);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _isScanNextRequested = false;
      });
      _showError('Could not process this page. Try again.');
    }
  }

  void _rotate() {
    if (!mounted || _isProcessing) return;
    setState(() => _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4);
    unawaited(_updateFinalPreview());
  }

  bool get _isEditingExistingPage => widget.initialCorners != null;

  /// Whether leaving now would lose anything the user changed: the crop or
  /// any appearance setting, relative to how this review opened.
  bool get _hasUnsavedChanges {
    final corners = _corners;
    final start = _startCorners;
    return (corners != null && start != null && !listEquals(corners, start)) ||
        _selectedFilter != widget.initialFilter ||
        _rotationQuarterTurns != widget.initialRotationQuarterTurns ||
        _brightness != widget.initialBrightness ||
        _contrast != widget.initialContrast;
  }

  /// One rule for Back and Cancel on the crop step. (Back from the
  /// appearance step only returns here, keeping every setting.) Explicit
  /// Skip, Retake and Stop importing never ask.
  _LeaveConfirmation? get _leaveConfirmation {
    // An unreadable image has nothing to lose, and leaving it moves on.
    if (_error != null) return null;
    if (_canStopImport) return _LeaveConfirmation.stopImport;
    if (_isNewCameraCapture) return _LeaveConfirmation.discardScan;
    if (_hasUnsavedChanges) return _LeaveConfirmation.discardChanges;
    return null;
  }

  bool _isConfirmingDiscard = false;

  Future<void> _confirmLeave() async {
    final confirmation = _leaveConfirmation;
    if (!mounted ||
        confirmation == null ||
        _isConfirmingDiscard ||
        _isLeaving ||
        _isProcessing ||
        _step != _Step.corners) {
      return;
    }
    _isConfirmingDiscard = true;
    final item = _batchItem.toLowerCase();
    final (title, body, keep, leave) = switch (confirmation) {
      _LeaveConfirmation.discardChanges => (
        'Discard changes?',
        null,
        'Keep editing',
        'Discard',
      ),
      _LeaveConfirmation.discardScan => (
        'Discard this scan?',
        null,
        'Keep editing',
        'Discard',
      ),
      _LeaveConfirmation.stopImport => (
        'Stop importing?',
        '${_hasUnsavedChanges ? 'Your changes are discarded. ' : ''}'
            'This $item and the remaining ones will not be added. '
            'Pages already added are kept.',
        'Keep reviewing',
        'Stop',
      ),
    };
    final bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: body == null ? null : Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(keep),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(leave),
            ),
          ],
        ),
      );
    } finally {
      _isConfirmingDiscard = false;
    }
    if (confirmed != true ||
        !mounted ||
        _isLeaving ||
        _isProcessing ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    // Navigator.pop bypasses canPop; onPopInvokedWithResult still runs and
    // stops a batch import.
    Navigator.of(context).pop();
  }

  bool get _isNewCameraCapture =>
      !_isEditingExistingPage && widget.source == PageReviewSource.camera;

  bool get _canScanNext => _isNewCameraCapture && widget.onScanNext != null;

  bool get _canRetake => _isNewCameraCapture && widget.onRetake != null;

  bool get _canSkipImage =>
      !_isEditingExistingPage &&
      widget.isBatchImport &&
      (widget.source == PageReviewSource.gallery ||
          widget.source == PageReviewSource.recovered ||
          widget.source == PageReviewSource.shared ||
          widget.source == PageReviewSource.pdf);

  bool get _hasBatchProgress =>
      _canSkipImage &&
      widget.batchPosition != null &&
      widget.batchCount != null;

  /// Stop importing is laid out on every batch image so the app bar never
  /// changes between images; it is only enabled while images remain.
  bool get _offersStopImport =>
      _hasBatchProgress && widget.onStopImport != null;

  bool get _canStopImport =>
      _offersStopImport && widget.batchPosition! < widget.batchCount!;

  void _stopImport() {
    if (!_canStopImport ||
        !mounted ||
        _isLeaving ||
        _isProcessing ||
        _step != _Step.corners ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    widget.onStopImport!();
    setState(() => _isLeaving = true);
    Navigator.of(context).pop();
  }

  /// Skip leaves at once; Cancel asks first, exactly as Back does.
  void _cancelReview() {
    if (!_canSkipImage && _leaveConfirmation != null) {
      unawaited(_confirmLeave());
      return;
    }
    _leaveReview(retake: false);
  }

  void _retake() => _leaveReview(retake: true);

  void _leaveReview({required bool retake}) {
    if (!mounted ||
        _isLeaving ||
        _isProcessing ||
        _step != _Step.corners ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    // The caller advances an import after this route returns. Ignore stale
    // taps during the reverse transition rather than popping another route.
    if (retake) {
      // The crop step's actions only show once the image is ready.
      final corners = _corners;
      if (corners == null) return;
      widget.onRetake!(
        PageReviewState(
          corners: List.of(corners),
          startCorners: List.of(_startCorners ?? corners),
          filter: _selectedFilter,
          rotationQuarterTurns: _rotationQuarterTurns,
          brightness: _brightness,
          contrast: _contrast,
        ),
      );
    }
    setState(() => _isLeaving = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final imageSize = _imageSize;
    final corners = _corners;
    final ready = imageSize != null && corners != null;

    return PopScope(
      // Back from the appearance step only returns to the crop step, which
      // keeps every setting; leaving the review asks first whenever it
      // would lose something (see _leaveConfirmation).
      canPop:
          !_isProcessing &&
          (_step != _Step.corners || _isLeaving || _leaveConfirmation == null),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_confirmLeave());
          return;
        }
        // Back during batch review leaves the import instead of silently
        // skipping to the next image; Skip image remains the explicit skip.
        // An unreadable image has nothing to review: leaving it moves on.
        if (!_isLeaving &&
            result == null &&
            _error == null &&
            _step == _Step.corners &&
            _canStopImport) {
          widget.onStopImport!();
        }
        _isLeaving = true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: _showsBatchProgressTitle
              // Scale down rather than ellipsize so the position stays
              // readable beside Stop importing at large text sizes.
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(_appBarTitle, key: const Key('batch_progress')),
                )
              : Text(_appBarTitle),
          actions: [
            if (_step == _Step.corners && _offersStopImport)
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: 'Stop importing',
                onPressed: !_canStopImport || _isLeaving || _isProcessing
                    ? null
                    : _stopImport,
              ),
            if (_step == _Step.filter) ...[
              IconButton(
                icon: const Icon(Icons.photo_filter_outlined),
                tooltip: 'Filters',
                // Marks the open side panel; never changes the button's size.
                isSelected: _sidePanel == _Panel.filters,
                onPressed: _isProcessing ? null : _showFilters,
              ),
              IconButton(
                icon: const Icon(Icons.tune_outlined),
                tooltip: 'Adjust',
                isSelected: _sidePanel == _Panel.adjust,
                onPressed: _isProcessing ? null : _showAdjustments,
              ),
              IconButton(
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                tooltip: 'Rotate clockwise',
                onPressed: _isProcessing ? null : _rotate,
              ),
            ],
          ],
        ),
        body: !ready
            ? Center(
                child: _error != null
                    ? _InitErrorView(message: _error!)
                    : const CircularProgressIndicator(),
              )
            : _step == _Step.corners
            ? _buildCornersStep(context, imageSize, corners)
            : _buildFilterStep(context),
      ),
    );
  }

  /// What one batch item is called: PDF imports are reviewed page by page.
  String get _batchItem =>
      widget.source == PageReviewSource.pdf ? 'Page' : 'Image';

  /// Batch position stays in the title on both steps, so the context and
  /// the title's place never change while reviewing an image.
  bool get _showsBatchProgressTitle => _hasBatchProgress;

  String get _appBarTitle {
    if (_showsBatchProgressTitle) {
      return '$_batchItem ${widget.batchPosition} of ${widget.batchCount}';
    }
    if (_step == _Step.filter) return 'Appearance';
    return _isEditingExistingPage ? 'Edit page' : 'Adjust corners';
  }

  Widget _buildCornersStep(
    BuildContext context,
    Size imageSize,
    List<Offset> corners,
  ) {
    // Keep handles out of the system gesture zones along the screen edges
    // the canvas touches, so a drag that starts on one never becomes Back
    // or Home. Edge handles are also excluded from the Back gesture.
    final gestureInsets = MediaQuery.systemGestureInsetsOf(context);
    EdgeInsets canvasPadding({required bool landscape}) => EdgeInsets.fromLTRB(
      math.max(8, gestureInsets.left),
      8,
      landscape ? 8 : math.max(8, gestureInsets.right),
      landscape ? math.max(8, gestureInsets.bottom) : 8,
    );
    Widget preview({required bool landscape}) => Padding(
      padding: canvasPadding(landscape: landscape),
      child: Stack(
        children: [
          Positioned.fill(
            child: CornerOverlay(
              imageBytes: widget.originalBytes,
              imageSize: imageSize,
              corners: corners,
              onChanged: _setCrop,
              onReset: _resetCrop,
            ),
          ),
          if (_cropProblem != null)
            _canvasNotice(
              context,
              key: const Key('crop_problem'),
              message: _cropProblemMessage(_cropProblem!),
            )
          else if (_fullImageNoticeMounted)
            _fullImageNotice(context),
        ],
      ),
    );
    Widget actions({required bool landscape}) {
      final secondary = OutlinedButton(
        onPressed: _isLeaving || _isProcessing
            ? null
            : _canRetake
            ? _retake
            : _cancelReview,
        child: _actionLabel(
          _canSkipImage
              ? 'Skip ${_batchItem.toLowerCase()}'
              : _canRetake
              ? 'Retake'
              : 'Cancel',
          // One line in every layout, so both buttons keep one height even
          // when large text would wrap only the longer label.
          singleLine: true,
        ),
      );
      final primary = FilledButton(
        onPressed:
            _isGeneratingPreviews ||
                _isLeaving ||
                _isProcessing ||
                _cropProblem != null
            ? null
            : _goToFilterStep,
        child: _isGeneratingPreviews
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : _actionLabel('Preview page', singleLine: true),
      );
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          // The landscape side column is narrow: stack full-width buttons,
          // primary first, as on the appearance step.
          child: landscape
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [primary, const SizedBox(height: 8), secondary],
                )
              : Row(
                  children: [
                    Expanded(child: secondary),
                    const SizedBox(width: 16),
                    Expanded(child: primary),
                  ],
                ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the crop canvas stable while guidance and large-text controls
        // scroll independently. A height cap on the canvas made it tiny on
        // short screens and whenever accessibility text scaling was enabled.
        if (constraints.maxWidth > constraints.maxHeight) {
          return Row(
            children: [
              Expanded(child: preview(landscape: true)),
              _sideColumn(
                constraints,
                scrollKey: const Key('batch_review_scroll_view'),
                child: actions(landscape: true),
              ),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: preview(landscape: false)),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.35,
              ),
              child: SingleChildScrollView(
                key: const Key('batch_review_scroll_view'),
                child: actions(landscape: false),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Landscape control column, shared by both steps so the canvas, preview
  /// and actions keep the same places when switching steps. Actions sit at
  /// the bottom, within thumb reach, and scroll only if they cannot fit.
  /// [panel] fills the space above them without moving them.
  Widget _sideColumn(
    BoxConstraints constraints, {
    required Key scrollKey,
    required Widget child,
    Widget? panel,
  }) => SizedBox(
    width: (constraints.maxWidth * 0.35).clamp(240.0, 320.0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: panel ?? const SizedBox.shrink()),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: constraints.maxHeight),
          child: SingleChildScrollView(key: scrollKey, child: child),
        ),
      ],
    ),
  );

  /// A button label that never wraps: it scales down instead, so narrow
  /// columns keep one-line buttons of a fixed height.
  Widget _actionLabel(String text, {required bool singleLine}) => singleLine
      ? FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(text, maxLines: 1, softWrap: false),
        )
      : Text(text, textAlign: TextAlign.center);

  /// Overlaid on the canvas (never in the column) so the canvas keeps its
  /// size when the notice fades after the first adjustment. Inset
  /// horizontally to stay clear of the top corner handles, and ignores
  /// pointers so a drag that starts beneath it still reaches the canvas.
  Widget _fullImageNotice(BuildContext context) => _canvasNotice(
    context,
    key: const Key('full_image_notice'),
    message: 'No page edges detected. Full image selected.',
    visible: _showFullImageNotice,
    onHidden: () {
      if (mounted && !_showFullImageNotice) {
        setState(() => _fullImageNoticeMounted = false);
      }
    },
  );

  static String _cropProblemMessage(CropProblem problem) =>
      '${switch (problem) {
        CropProblem.cornersCross => 'Corners cross each other.',
        CropProblem.cornerInside => 'A corner is inside the crop.',
        CropProblem.areaTooSmall => 'Crop is too small.',
      }} Double-tap the image to reset.';

  /// A pill over the top of the canvas. It never takes layout space and
  /// ignores pointers, so drags beneath it still reach the handles.
  Widget _canvasNotice(
    BuildContext context, {
    required Key key,
    required String message,
    bool visible = true,
    VoidCallback? onHidden,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 8,
      left: 56,
      right: 56,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          onEnd: onHidden,
          child: Center(
            child: Material(
              key: key,
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
              elevation: 1,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _setCrop(List<Offset> corners) {
    setState(() {
      _corners = corners;
      _cropProblem = cropProblem(corners);
      _showFullImageNotice = false;
    });
    unawaited(_updatePreviews());
  }

  void _resetCrop() {
    final start = _startCorners;
    if (start == null || _isProcessing || _isLeaving) return;
    // A fresh list so the overlay resyncs its live corners.
    _setCrop([...start]);
  }

  Widget _resetAdjustmentsButton({required VoidCallback onSheetChanged}) =>
      TextButton(
        onPressed: _isProcessing
            ? null
            : () {
                setState(() {
                  _brightness = 0;
                  _contrast = 1;
                  _finalPreviewGeneration++;
                  _previewStatus = _PreviewStatus.pending;
                });
                onSheetChanged();
                unawaited(_updateFinalPreview());
              },
        child: const Text('Reset adjustments'),
      );

  /// Gapless: new bytes (a rotation, a filter, an adjustment) replace the
  /// previous image only once decoded, so the preview never blanks between
  /// the two. The image is fitted inside its slot, so a rotation that flips
  /// the aspect ratio never resizes the slot.
  Widget _boundedPreviewImage(
    Uint8List bytes, {
    Key? key,
    required BoxFit fit,
    required int maxDimension,
  }) => Image(
    key: key,
    gaplessPlayback: true,
    image: ResizeImage(
      MemoryImage(bytes),
      width: maxDimension,
      height: maxDimension,
      policy: ResizeImagePolicy.fit,
    ),
    fit: fit,
  );

  Widget _buildFilterStep(BuildContext context) {
    final previewBytes = _finalPreviewBytes;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Filters and brightness/contrast open on demand, so only the
        // confirm buttons share the screen with the preview. Large text
        // scales those buttons, which the fixed layout absorbs; only very
        // short viewports need to scroll.
        _isSideBySide = constraints.maxWidth > constraints.maxHeight;
        if (_isSideBySide) {
          // Side by side: the preview keeps the full height and the confirm
          // buttons stay visible, without scrolling, in the side column.
          // Filters and Adjust open above them, never over the preview.
          return Row(
            children: [
              Expanded(child: _filterPreview(previewBytes)),
              _sideColumn(
                constraints,
                scrollKey: const Key('filter_step_controls'),
                child: _filterActions(singleLine: true),
                panel: _sidePanelView(context),
              ),
            ],
          );
        }
        // A panel opened side by side has no place in this layout.
        if (_sidePanel != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _closeSidePanel(),
          );
        }
        if (constraints.maxHeight >= 480) {
          return Column(
            children: [
              Expanded(child: _filterPreview(previewBytes)),
              _filterActions(),
            ],
          );
        }

        final previewHeight = (constraints.maxHeight * 0.45).clamp(
          120.0,
          280.0,
        );
        return SingleChildScrollView(
          key: const Key('filter_step_scroll_view'),
          child: Column(
            children: [
              SizedBox(
                height: previewHeight,
                child: _filterPreview(previewBytes),
              ),
              _filterActions(),
            ],
          ),
        );
      },
    );
  }

  // Preview status is layered over the preview instead of being inserted
  // into the column, so the preview, adjustment controls and confirm buttons
  // never move or resize while a preview is pending, updating or failed.
  Widget _filterPreview(Uint8List? previewBytes) => Padding(
    key: const Key('adjusted_page_preview'),
    padding: const EdgeInsets.all(16),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (previewBytes != null)
          _boundedPreviewImage(
            previewBytes,
            key: const Key('adjusted_page_image'),
            fit: BoxFit.contain,
            maxDimension: _fullPreviewDecodeSize,
          ),
        Positioned.fill(child: _previewStatusOverlay(previewBytes != null)),
      ],
    ),
  );

  String? _previewStatusMessage({required bool hasPreview}) =>
      switch (_previewStatus) {
        _PreviewStatus.pending || _PreviewStatus.ready => null,
        _PreviewStatus.updating => 'Updating preview…',
        _PreviewStatus.failed =>
          hasPreview
              ? 'Could not update the preview. Showing the previous one.'
              : 'Preview unavailable',
      };

  Widget _previewStatusOverlay(bool hasPreview) {
    final message = _previewStatusMessage(hasPreview: hasPreview);
    final failed = _previewStatus == _PreviewStatus.failed;
    final scheme = Theme.of(context).colorScheme;
    final Widget? pill = message == null
        ? null
        : Material(
            key: const Key('preview_status'),
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
            elevation: 1,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(message, textAlign: TextAlign.center),
                  ),
                  if (failed)
                    TextButton.icon(
                      onPressed: _isProcessing ? null : _updateFinalPreview,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry preview'),
                    ),
                ],
              ),
            ),
          );
    final Widget? status = pill == null || failed
        ? pill
        : IgnorePointer(child: pill);
    if (!hasPreview) {
      // Nothing to protect yet: centre the placeholder with the status under
      // it. Scrolls (instead of overflowing) in very short previews.
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_previewStatus == _PreviewStatus.updating)
                const CircularProgressIndicator()
              else
                const Icon(Icons.image_not_supported_outlined, size: 48),
              if (status != null) ...[const SizedBox(height: 8), status],
            ],
          ),
        ),
      );
    }
    if (status == null) return const SizedBox.shrink();
    // Top-aligned so it stays visible above the Filters/Adjust sheets.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: status,
      ),
    );
  }

  /// [value], [min] and [max] are slider positions; [describe] turns a
  /// position into the value shown, [announce] into the value read aloud.
  Widget _adjustmentSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String Function(double position) describe,
    required String Function(double position) announce,
    required ValueChanged<double> onChanged,
    required VoidCallback onSheetChanged,
  }) {
    final displayValue = describe(value);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The slider announces its own label and value.
          ExcludeSemantics(child: Text('$label: $displayValue')),
          MergeSemantics(
            child: Semantics(
              label: label,
              // Dragging from the track's ends must not trigger system Back.
              child: GestureExclusionRegion(
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  semanticFormatterCallback: announce,
                  onChanged: _isProcessing
                      ? null
                      : (newValue) {
                          if (!mounted || _isProcessing) return;
                          setState(() {
                            onChanged(newValue);
                            _finalPreviewGeneration++;
                            _previewStatus = _PreviewStatus.pending;
                          });
                          onSheetChanged();
                        },
                  onChangeEnd: _isProcessing
                      ? null
                      : (_) => unawaited(_updateFinalPreview()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Header shared by the Filters and Adjust sheets and side panels.
  Widget _panelHeader(
    BuildContext context,
    String title, {
    required VoidCallback onClose,
  }) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      IconButton(
        tooltip: 'Close',
        icon: const Icon(Icons.close),
        onPressed: onClose,
      ),
    ],
  );

  /// [refresh] rebuilds the sheet route, whose content does not rebuild
  /// with this state.
  Widget _filtersContent(
    BuildContext context, {
    required VoidCallback onClose,
    required VoidCallback refresh,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _panelHeader(context, 'Filters', onClose: onClose),
        Wrap(
          spacing: 12,
          runSpacing: 16,
          children: [
            for (final filter in PageFilter.values)
              _filterChip(context, filter, onSelected: refresh),
          ],
        ),
      ],
    ),
  );

  /// Brightness, contrast and Reset. Values live in this state, so they
  /// persist across openings; the preview updates when a slider is released.
  Widget _adjustContent(
    BuildContext context, {
    required VoidCallback onClose,
    required VoidCallback refresh,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _panelHeader(context, 'Adjust', onClose: onClose),
      ),
      _adjustmentSlider(
        label: 'Brightness',
        value: _brightness,
        min: -100,
        max: 100,
        describe: (v) => '${v > 0 ? '+' : ''}${v.round()}',
        announce: (v) => '${v.round()}, neutral 0',
        onChanged: (value) => _brightness = value,
        onSheetChanged: refresh,
      ),
      _adjustmentSlider(
        label: 'Contrast',
        // Log scale: neutral 1.0× sits in the middle.
        value: contrastToSliderPosition(_contrast),
        min: -1,
        max: 1,
        describe: (position) =>
            '${sliderPositionToContrast(position).toStringAsFixed(2)}×',
        announce: (position) =>
            '${sliderPositionToContrast(position).toStringAsFixed(2)} '
            'times, neutral 1',
        onChanged: (position) => _contrast = sliderPositionToContrast(position),
        onSheetChanged: refresh,
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _resetAdjustmentsButton(onSheetChanged: refresh),
        ),
      ),
    ],
  );

  Future<void> _showFilters() => _showPanel(_Panel.filters);

  Future<void> _showAdjustments() => _showPanel(_Panel.adjust);

  /// Side by side, toggles [panel] in the control column; otherwise opens
  /// it as a bottom sheet. Either way Back closes it before leaving the
  /// step.
  Future<void> _showPanel(_Panel panel) async {
    if (_isProcessing || _isLeaving || _step != _Step.filter) return;
    if (_isSideBySide) {
      _toggleSidePanel(panel);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // No scrim: the preview behind shows the effect while choosing.
      barrierColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) {
          void refresh() => updateSheet(() {});
          void close() => Navigator.of(sheetContext).pop();
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.75,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.only(
                  top: 16,
                  bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: switch (panel) {
                  _Panel.filters => _filtersContent(
                    context,
                    onClose: close,
                    refresh: refresh,
                  ),
                  _Panel.adjust => _adjustContent(
                    context,
                    onClose: close,
                    refresh: refresh,
                  ),
                },
              ),
            ),
          );
        },
      ),
    );
  }

  void _toggleSidePanel(_Panel panel) {
    if (_sidePanel == panel) {
      _closeSidePanel();
      return;
    }
    setState(() => _sidePanel = panel);
    if (_panelHistoryEntry != null) return;
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      onRemove: () {
        if (identical(_panelHistoryEntry, entry)) _panelHistoryEntry = null;
        if (mounted && _sidePanel != null) {
          setState(() => _sidePanel = null);
        }
      },
    );
    _panelHistoryEntry = entry;
    ModalRoute.of(context)?.addLocalHistoryEntry(entry);
  }

  void _closeSidePanel() {
    final entry = _panelHistoryEntry;
    if (entry != null) {
      entry.remove();
    } else if (mounted && _sidePanel != null) {
      setState(() => _sidePanel = null);
    }
  }

  Widget? _sidePanelView(BuildContext context) {
    final panel = _sidePanel;
    if (panel == null) return null;
    void refresh() {}
    return Material(
      key: const Key('appearance_side_panel'),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: switch (panel) {
          _Panel.filters => _filtersContent(
            context,
            onClose: _closeSidePanel,
            refresh: refresh,
          ),
          _Panel.adjust => _adjustContent(
            context,
            onClose: _closeSidePanel,
            refresh: refresh,
          ),
        },
      ),
    );
  }

  Widget _filterActions({bool singleLine = false}) {
    Widget label(String text, {required bool busy}) => busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : _actionLabel(text, singleLine: singleLine);
    final List<Widget> buttons;
    if (_canScanNext) {
      // Stacked full-width buttons keep both labels readable at large text
      // sizes on narrow phones, and a progress indicator never changes widths.
      buttons = [
        FilledButton(
          onPressed: _canConfirm ? () => _confirm(scanNext: true) : null,
          child: label(
            'Add & scan next',
            busy: _isProcessing && _isScanNextRequested,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _canConfirm ? _confirm : null,
          child: label(
            'Add page',
            busy: _isProcessing && !_isScanNextRequested,
          ),
        ),
      ];
    } else {
      buttons = [
        FilledButton(
          onPressed: _canConfirm ? _confirm : null,
          child: label(
            _isEditingExistingPage ? 'Save changes' : 'Add page',
            busy: _isProcessing,
          ),
        ),
      ];
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...buttons],
        ),
      ),
    );
  }

  Widget _filterChip(
    BuildContext context,
    PageFilter filter, {
    required VoidCallback onSelected,
  }) {
    final selected = _selectedFilter == filter;
    final previewBytes = _filterPreviews?[filter];
    final primary = Theme.of(context).colorScheme.primary;
    final VoidCallback? select = _isProcessing
        ? null
        : () {
            if (!mounted || _isProcessing) return;
            setState(() => _selectedFilter = filter);
            onSelected();
            unawaited(_updateFinalPreview());
          };
    // One node per tile: the visible label is not read a second time.
    return Semantics(
      key: ValueKey('filter_${filter.name}'),
      button: true,
      enabled: !_isProcessing,
      selected: selected,
      label: '${_filterLabels[filter]} filter',
      onTap: select,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: select,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? primary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: previewBytes != null
                    ? _boundedPreviewImage(
                        previewBytes,
                        fit: BoxFit.cover,
                        maxDimension: _filterChipDecodeSize,
                      )
                    : ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: _isGeneratingPreviews
                            ? const Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                _filterLabels[filter]!,
                // Selection changes the colour only: a bolder label would
                // widen the tile and shift the tiles after it.
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? primary : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InitErrorView extends StatelessWidget {
  const _InitErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Go back'),
          ),
        ],
      ),
    );
  }
}
