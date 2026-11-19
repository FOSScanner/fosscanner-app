import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';

import '../models/scanned_page.dart';
import '../services/corner_adjust_operations.dart';
import '../services/corner_geometry.dart';
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
enum PageReviewSource { camera, gallery, recovered }

enum _Step { corners, filter }

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
    this.initialCorners,
    this.startWithAdjustments = false,
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
  final List<Offset>? initialCorners;

  /// Open saved appearance directly; crop remains available.
  final bool startWithAdjustments;
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
  bool _showFullImageNotice = false;
  bool _isProcessing = false;
  bool _isLeaving = false;
  String? _error;
  late final ImageProcessingQueue _processingQueue;
  int _initializationGeneration = 0;
  int _exportGeneration = 0;

  _Step _step = _Step.corners;
  LocalHistoryEntry? _filterHistoryEntry;
  late PageFilter _selectedFilter = widget.initialFilter;
  late int _rotationQuarterTurns = widget.initialRotationQuarterTurns;
  late double _brightness = widget.initialBrightness;
  late double _contrast = widget.initialContrast;
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

      List<Offset>? candidateCorners = widget.initialCorners;
      if (candidateCorners == null) {
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
      final corners = hasCorners ? candidateCorners! : _fullBoundsCorners(size);

      if (!mounted) return;
      setState(() {
        _imageSize = size;
        _corners = corners;
        _showFullImageNotice = !hasCorners;
      });
      if (widget.startWithAdjustments && hasCorners) _enterFilterStep();
      unawaited(_updatePreviews());
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Corner initialization failed (${error.runtimeType}).');
      }
      if (!mounted) return;
      setState(() {
        _error = 'Could not read this photo.';
      });
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

    // Keep geometry failures separate from decoder/backend failures so the
    // recovery guidance matches what the user can actually fix.
    try {
      calculateWarpSize(
        corners,
        maxPixels: maxPreviewWarpPixels,
        maxEdge: maxPreviewWarpEdge,
      );
    } on ArgumentError {
      if (!mounted || generation != _previewGeneration) return;
      setState(() => _isGeneratingPreviews = false);
      _showError(
        'Could not preview this crop. Adjust the corners and try again.',
      );
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
      _showError('Could not process this photo. Try another image.');
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
    if (!mounted || _isLeaving || _isProcessing) return;
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

  Future<void> _confirm() async {
    final corners = _corners;
    if (corners == null || !_canConfirm) return;
    final filter = _selectedFilter;
    final rotationQuarterTurns = _rotationQuarterTurns;
    final brightness = _brightness;
    final contrast = _contrast;
    _previewGeneration++;
    _finalPreviewGeneration++;
    final exportGeneration = ++_exportGeneration;
    setState(() {
      _isProcessing = true;
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
      _filterHistoryEntry?.remove();
      if (mounted) Navigator.of(context).pop(page);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _showError('Could not process this page. Try another image.');
    }
  }

  void _rotate() {
    if (!mounted || _isProcessing) return;
    setState(() => _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4);
    unawaited(_updateFinalPreview());
  }

  bool get _isEditingExistingPage => widget.initialCorners != null;

  bool get _canSkipImage =>
      !_isEditingExistingPage &&
      widget.isBatchImport &&
      (widget.source == PageReviewSource.gallery ||
          widget.source == PageReviewSource.recovered);

  bool get _hasBatchProgress =>
      _canSkipImage &&
      widget.batchPosition != null &&
      widget.batchCount != null;

  /// Stop importing is laid out on every batch image so the app bar does not
  /// change between images; it is only enabled while images remain.
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

  void _cancelReview() {
    if (!mounted ||
        _isLeaving ||
        _isProcessing ||
        _step != _Step.corners ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    // The caller advances an import after this route returns. Ignore stale
    // taps during the reverse transition rather than popping another route.
    setState(() => _isLeaving = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final imageSize = _imageSize;
    final corners = _corners;
    final ready = imageSize != null && corners != null;

    return PopScope(
      canPop: !_isProcessing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        // Back during batch review leaves the import instead of silently
        // skipping to the next image; Skip image remains the explicit skip.
        if (!_isLeaving &&
            result == null &&
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
                icon: const Icon(Icons.filter_alt_outlined),
                tooltip: 'Filters',
                onPressed: _isProcessing ? null : _showFilters,
              ),
              IconButton(
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                tooltip: 'Rotate',
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

  bool get _showsBatchProgressTitle =>
      _step == _Step.corners && _hasBatchProgress;

  String get _appBarTitle {
    if (_step == _Step.filter) return 'Adjust appearance';
    if (_showsBatchProgressTitle) {
      return 'Image ${widget.batchPosition} of ${widget.batchCount}';
    }
    return _isEditingExistingPage ? 'Edit page' : 'Adjust corners';
  }

  Widget _buildCornersStep(
    BuildContext context,
    Size imageSize,
    List<Offset> corners,
  ) {
    final preview = Padding(
      padding: const EdgeInsets.all(8),
      child: CornerOverlay(
        imageBytes: widget.originalBytes,
        imageSize: imageSize,
        corners: corners,
        onChanged: _setCrop,
      ),
    );
    final actions = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showFullImageNotice)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Semantics(
              liveRegion: true,
              child: Text(
                'No page edges detected. Full image selected.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        if (_canSkipImage)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Semantics(
              liveRegion: true,
              child: const Text(
                'Skip this image only. Any remaining images will still be reviewed.',
              ),
            ),
          ),

        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isLeaving || _isProcessing
                        ? null
                        : _cancelReview,
                    child: Text(_canSkipImage ? 'Skip image' : 'Cancel'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        _isGeneratingPreviews || _isLeaving || _isProcessing
                        ? null
                        : _goToFilterStep,
                    child: _isGeneratingPreviews
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Preview page'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final controls = SingleChildScrollView(
          key: const Key('batch_review_scroll_view'),
          child: actions,
        );
        // Keep the crop canvas stable while guidance and large-text controls
        // scroll independently. A height cap on the canvas made it tiny on
        // short screens and whenever accessibility text scaling was enabled.
        if (constraints.maxWidth > constraints.maxHeight) {
          return Row(
            children: [
              Expanded(child: preview),
              SizedBox(
                width: (constraints.maxWidth * 0.35).clamp(240.0, 320.0),
                child: controls,
              ),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: preview),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.35,
              ),
              child: controls,
            ),
          ],
        );
      },
    );
  }

  void _setCrop(List<Offset> corners) {
    setState(() {
      _corners = corners;
      _showFullImageNotice = false;
    });
    unawaited(_updatePreviews());
  }

  Widget _resetAdjustmentsButton() => TextButton(
    onPressed: _isProcessing
        ? null
        : () {
            setState(() {
              _brightness = 0;
              _contrast = 1;
              _finalPreviewGeneration++;
              _previewStatus = _PreviewStatus.pending;
            });
            unawaited(_updateFinalPreview());
          },
    child: const Text('Reset adjustments'),
  );

  Widget _boundedPreviewImage(
    Uint8List bytes, {
    required BoxFit fit,
    required int maxDimension,
  }) => Image(
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
        final useScrollableLayout =
            constraints.maxHeight < 480 ||
            MediaQuery.textScalerOf(context).scale(16) > 20;
        if (!useScrollableLayout) {
          return Column(
            children: [
              Expanded(child: _filterPreview(previewBytes)),
              _adjustmentSlider(
                label: 'Brightness',
                value: _brightness,
                min: -100,
                max: 100,
                onChanged: (value) => _brightness = value,
              ),
              _adjustmentSlider(
                label: 'Contrast',
                value: _contrast,
                min: 0.5,
                max: 2.0,
                onChanged: (value) => _contrast = value,
              ),
              _resetAdjustmentsButton(),
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
              _adjustmentSlider(
                label: 'Brightness',
                value: _brightness,
                min: -100,
                max: 100,
                onChanged: (value) => _brightness = value,
              ),
              _adjustmentSlider(
                label: 'Contrast',
                value: _contrast,
                min: 0.5,
                max: 2.0,
                onChanged: (value) => _contrast = value,
              ),
              _resetAdjustmentsButton(),
              _filterActions(),
            ],
          ),
        );
      },
    );
  }

  Widget _filterPreview(Uint8List? previewBytes) => Padding(
    key: const Key('adjusted_page_preview'),
    padding: const EdgeInsets.all(16),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (previewBytes != null)
          _boundedPreviewImage(
            previewBytes,
            fit: BoxFit.contain,
            maxDimension: _fullPreviewDecodeSize,
          ),
        if (previewBytes == null)
          Center(
            child: _previewStatus == _PreviewStatus.updating
                ? const CircularProgressIndicator()
                : const Icon(Icons.image_not_supported_outlined, size: 48),
          ),
      ],
    ),
  );

  Widget _adjustmentSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    final displayValue = label == 'Brightness'
        ? '${value > 0 ? '+' : ''}${value.round()}'
        : '${value.toStringAsFixed(2)}×';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: $displayValue'),
          MergeSemantics(
            child: Semantics(
              label: label,
              child: Slider(
                value: value,
                min: min,
                max: max,
                semanticFormatterCallback: (v) => label == 'Brightness'
                    ? '${v.round()}, neutral 0'
                    : '${v.toStringAsFixed(2)} times, neutral 1',
                onChanged: _isProcessing
                    ? null
                    : (newValue) {
                        if (!mounted || _isProcessing) return;
                        setState(() {
                          onChanged(newValue);
                          _finalPreviewGeneration++;
                          _previewStatus = _PreviewStatus.pending;
                        });
                      },
                onChangeEnd: _isProcessing
                    ? null
                    : (_) => unawaited(_updateFinalPreview()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showFilters() async {
    if (_isProcessing || _isLeaving || _step != _Step.filter) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Filters',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close filters',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 16,
                    children: [
                      for (final filter in PageFilter.values)
                        _filterChip(
                          context,
                          filter,
                          onSelected: () => updateSheet(() {}),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewFeedback() {
    final message = switch (_previewStatus) {
      _PreviewStatus.pending => 'Release the slider to update the preview.',
      _PreviewStatus.updating =>
        _finalPreviewBytes == null
            ? 'Updating preview...'
            : 'Updating preview. Previous result shown.',
      _PreviewStatus.failed =>
        _finalPreviewBytes == null
            ? 'Preview unavailable. Retry to review this page.'
            : 'Preview could not be updated. Previous result shown.',
      _PreviewStatus.ready => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(liveRegion: true, child: Text(message)),
        if (_previewStatus == _PreviewStatus.failed)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: _isProcessing ? null : _updateFinalPreview,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry preview'),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _filterActions() {
    final confirm = FilledButton(
      onPressed: _canConfirm ? _confirm : null,
      child: _isProcessing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(_isEditingExistingPage ? 'Save changes' : 'Add page'),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_previewStatus != _PreviewStatus.ready) _previewFeedback(),
            confirm,
          ],
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
    return Semantics(
      key: ValueKey('filter_${filter.name}'),
      button: true,
      enabled: !_isProcessing,
      selected: selected,
      label: '${_filterLabels[filter]} filter',
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isProcessing
              ? null
              : () {
                  if (!mounted || _isProcessing) return;
                  setState(() => _selectedFilter = filter);
                  onSelected();
                  unawaited(_updateFinalPreview());
                },
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
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? primary : null,
                  fontWeight: selected ? FontWeight.bold : null,
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
