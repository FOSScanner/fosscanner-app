import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../models/scanned_page.dart';
import '../services/corner_geometry.dart';
import '../services/document_processor.dart';
import '../widgets/corner_overlay.dart';
import '../widgets/transient_message.dart';

const _fullPreviewDecodeSize = 2048;
const _filterChipDecodeSize = 256;

abstract interface class CornerAdjustOperations {
  Future<Size> decodeSize(Uint8List imageBytes);

  Future<List<Offset>?> detectCorners(Uint8List imageBytes);

  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  );

  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  });

  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  });
}

typedef _PreviewWorkerRequest = ({
  Uint8List imageBytes,
  List<double> cornerCoordinates,
});
typedef _FinalPreviewWorkerRequest = ({
  Uint8List imageBytes,
  int rotationQuarterTurns,
  double brightness,
  double contrast,
});
typedef _ExportWorkerRequest = ({
  Uint8List imageBytes,
  List<double> cornerCoordinates,
  PageFilter filter,
  int rotationQuarterTurns,
  double brightness,
  double contrast,
});

List<double> _serializeCorners(List<Offset> corners) => [
  for (final corner in corners) ...[corner.dx, corner.dy],
];

List<Offset> _deserializeCorners(List<double> coordinates) => [
  for (var i = 0; i < coordinates.length; i += 2)
    Offset(coordinates[i], coordinates[i + 1]),
];

List<double>? _detectCornersWorker(Uint8List imageBytes) {
  final corners = detectCorners(imageBytes);
  return corners == null ? null : _serializeCorners(corners);
}

Map<PageFilter, Uint8List> _buildPreviewsWorker(_PreviewWorkerRequest request) {
  final warped = warpDocument(
    request.imageBytes,
    _deserializeCorners(request.cornerCoordinates),
    maxPixels: maxPreviewWarpPixels,
    maxEdge: maxPreviewWarpEdge,
  );
  return {
    for (final filter in PageFilter.values) filter: applyFilter(warped, filter),
  };
}

Uint8List _buildFinalPreviewWorker(_FinalPreviewWorkerRequest request) {
  final rotated = rotateImage(request.imageBytes, request.rotationQuarterTurns);
  return adjustBrightnessContrast(
    rotated,
    brightness: request.brightness,
    contrast: request.contrast,
  );
}

Uint8List _processForExportWorker(_ExportWorkerRequest request) =>
    processDocument(
      request.imageBytes,
      _deserializeCorners(request.cornerCoordinates),
      filter: request.filter,
      rotationQuarterTurns: request.rotationQuarterTurns,
      brightness: request.brightness,
      contrast: request.contrast,
    );

class DefaultCornerAdjustOperations implements CornerAdjustOperations {
  const DefaultCornerAdjustOperations();

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    ui.FrameInfo? frame;
    try {
      frame = await codec.getNextFrame();
      return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    } finally {
      frame?.image.dispose();
      codec.dispose();
    }
  }

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async {
    final coordinates = await compute(_detectCornersWorker, imageBytes);
    return coordinates == null ? null : _deserializeCorners(coordinates);
  }

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) => compute(_buildPreviewsWorker, (
    imageBytes: imageBytes,
    cornerCoordinates: _serializeCorners(corners),
  ));

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) => compute(_buildFinalPreviewWorker, (
    imageBytes: imageBytes,
    rotationQuarterTurns: rotationQuarterTurns,
    brightness: brightness,
    contrast: contrast,
  ));

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) => compute(_processForExportWorker, (
    imageBytes: imageBytes,
    cornerCoordinates: _serializeCorners(corners),
    filter: filter,
    rotationQuarterTurns: rotationQuarterTurns,
    brightness: brightness,
    contrast: contrast,
  ));
}

class _QueuedWorkResult<T> {
  const _QueuedWorkResult.started(this.value) : started = true;
  const _QueuedWorkResult.skipped() : started = false, value = null;

  final bool started;
  final T? value;
}

/// Serializes OpenCV workers owned by one scanner session.
///
/// A route may be disposed before its worker finishes, so every editor opened
/// by the same home screen must share this queue.
class ImageProcessingQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() work) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await work());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

const _filterLabels = {
  PageFilter.original: 'Original',
  PageFilter.autoEnhance: 'Enhance',
  PageFilter.grayscale: 'Gray',
  PageFilter.blackAndWhite: 'B&W',
};

enum _Step { corners, filter }

/// Post-capture review, in two steps:
///
/// 1. Adjust corners on the raw photo (pre-filled from auto-detection when
///    possible).
/// 2. A full-size preview of the perspective-corrected page with the
///    selected filter actually applied — not just a small chip thumbnail —
///    so the user sees what they're about to save before confirming.
///
/// Also used for Phase 3 re-editing, in which case [initialCorners] is the
/// page's previously saved corners rather than a fresh detection.
class CornerAdjustScreen extends StatefulWidget {
  const CornerAdjustScreen({
    super.key,
    required this.originalBytes,
    this.initialCorners,
    this.initialFilter = PageFilter.original,
    this.initialRotationQuarterTurns = 0,
    this.initialBrightness = 0.0,
    this.initialContrast = 1.0,
    this.operations = const DefaultCornerAdjustOperations(),
    this.processingQueue,
  });

  final Uint8List originalBytes;
  final List<Offset>? initialCorners;
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
  bool _isProcessing = false;
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
  Uint8List? _finalPreviewBytes;
  bool _isGeneratingFinalPreview = false;
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
      final corners = _hasRenderableCorners(candidateCorners)
          ? candidateCorners!
          : _fullBoundsCorners(size);

      if (!mounted) return;
      setState(() {
        _imageSize = size;
        _corners = corners;
      });
      unawaited(_updatePreviews());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read this photo: $e';
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
    const marginFrac = 0.05;
    final mx = size.width * marginFrac;
    final my = size.height * marginFrac;
    return [
      Offset(mx, my),
      Offset(size.width - mx, my),
      Offset(size.width - mx, size.height - my),
      Offset(mx, size.height - my),
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
      _isGeneratingFinalPreview = false;
      _filterPreviews = null;
      _finalPreviewBytes = null;
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
    final base = _filterPreviews?[_selectedFilter];
    if (base == null || !mounted) return;
    final rotationQuarterTurns = _rotationQuarterTurns;
    final brightness = _brightness;
    final contrast = _contrast;
    final generation = ++_finalPreviewGeneration;
    setState(() {
      _isGeneratingFinalPreview = true;
      _finalPreviewBytes = null;
    });

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
        _isGeneratingFinalPreview = false;
      });
    } catch (_) {
      if (!mounted || generation != _finalPreviewGeneration) return;
      // This is preview-only; Confirm recomputes from scratch if it fails.
      setState(() => _isGeneratingFinalPreview = false);
    }
  }

  Future<void> _goToFilterStep() async {
    if (_filterPreviews == null) {
      await _updatePreviews();
      if (!mounted || _filterPreviews == null) return;
    }
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

  void _leaveFilterStep() {
    final entry = _filterHistoryEntry;
    if (entry != null) {
      entry.remove();
    } else if (_step == _Step.filter) {
      setState(() => _step = _Step.corners);
    }
  }

  Future<void> _confirm() async {
    final corners = _corners;
    if (corners == null || _isProcessing) return;
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
      _isGeneratingFinalPreview = false;
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
    setState(() => _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4);
    unawaited(_updateFinalPreview());
  }

  bool get _isEditingExistingPage => widget.initialCorners != null;

  @override
  Widget build(BuildContext context) {
    final imageSize = _imageSize;
    final corners = _corners;
    final ready = imageSize != null && corners != null;

    return PopScope(
      canPop: !_isProcessing,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_appBarTitle),
          actions: [
            if (_step == _Step.filter)
              IconButton(
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                tooltip: 'Rotate',
                onPressed: _isProcessing ? null : _rotate,
              ),
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

  String get _appBarTitle {
    if (_step == _Step.filter) return 'Preview';
    return _isEditingExistingPage ? 'Edit page' : 'Adjust corners';
  }

  Widget _buildCornersStep(
    BuildContext context,
    Size imageSize,
    List<Offset> corners,
  ) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CornerOverlay(
              imageBytes: widget.originalBytes,
              imageSize: imageSize,
              corners: corners,
              onChanged: (c) {
                setState(() => _corners = c);
                unawaited(_updatePreviews());
              },
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
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(_isEditingExistingPage ? 'Cancel' : 'Retake'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: _isGeneratingPreviews ? null : _goToFilterStep,
                    child: _isGeneratingPreviews
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Next'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

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
    final previewBytes =
        _finalPreviewBytes ?? _filterPreviews?[_selectedFilter];
    return Column(
      children: [
        Expanded(
          child: Padding(
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
                if (previewBytes == null || _isGeneratingFinalPreview)
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const SizedBox(width: 72, child: Text('Brightness')),
              Expanded(
                child: Slider(
                  value: _brightness,
                  min: -100,
                  max: 100,
                  onChanged: _isProcessing
                      ? null
                      : (v) => setState(() => _brightness = v),
                  onChangeEnd: _isProcessing
                      ? null
                      : (_) => unawaited(_updateFinalPreview()),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const SizedBox(width: 72, child: Text('Contrast')),
              Expanded(
                child: Slider(
                  value: _contrast,
                  min: 0.5,
                  max: 2.0,
                  onChanged: _isProcessing
                      ? null
                      : (v) => setState(() => _contrast = v),
                  onChangeEnd: _isProcessing
                      ? null
                      : (_) => unawaited(_updateFinalPreview()),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final filter in PageFilter.values)
                _filterChip(context, filter),
            ],
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
                    onPressed: _isProcessing ? null : _leaveFilterStep,
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: _isProcessing ? null : _confirm,
                    child: _isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Confirm'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _filterChip(BuildContext context, PageFilter filter) {
    final selected = _selectedFilter == filter;
    final previewBytes = _filterPreviews?[filter];
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: GestureDetector(
        onTap: _isProcessing
            ? null
            : () {
                setState(() => _selectedFilter = filter);
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
