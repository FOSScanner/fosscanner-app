import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/scanned_page.dart';
import '../services/document_processor.dart';
import '../widgets/corner_overlay.dart';

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
  });

  final Uint8List originalBytes;
  final List<Offset>? initialCorners;
  final PageFilter initialFilter;

  @override
  State<CornerAdjustScreen> createState() => _CornerAdjustScreenState();
}

class _CornerAdjustScreenState extends State<CornerAdjustScreen> {
  Size? _imageSize;
  List<Offset>? _corners;
  bool _isProcessing = false;
  String? _error;

  _Step _step = _Step.corners;
  late PageFilter _selectedFilter = widget.initialFilter;
  // Cache of the current corners' warp + per-filter previews, so dragging
  // doesn't redo expensive OpenCV work every frame (only on drag-end), and
  // so the filter step / Confirm can reuse this instead of recomputing.
  Uint8List? _warpedForPreview;
  Map<PageFilter, Uint8List>? _filterPreviews;
  bool _isGeneratingPreviews = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.originalBytes);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();

      final corners = widget.initialCorners ??
          detectCorners(widget.originalBytes) ??
          _fullBoundsCorners(size);

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

  Future<void> _updatePreviews() async {
    final corners = _corners;
    if (corners == null) return;
    setState(() => _isGeneratingPreviews = true);
    try {
      final warped = warpDocument(widget.originalBytes, corners);
      final previews = <PageFilter, Uint8List>{
        for (final f in PageFilter.values) f: applyFilter(warped, f),
      };
      if (!mounted) return;
      setState(() {
        _warpedForPreview = warped;
        _filterPreviews = previews;
        _isGeneratingPreviews = false;
      });
    } catch (_) {
      // Previews are a nice-to-have; if generation fails, Confirm still
      // falls back to computing fresh from the current corners.
      if (!mounted) return;
      setState(() => _isGeneratingPreviews = false);
    }
  }

  Future<void> _goToFilterStep() async {
    if (_filterPreviews == null) {
      await _updatePreviews();
      if (!mounted) return;
    }
    setState(() => _step = _Step.filter);
  }

  Future<void> _confirm() async {
    final corners = _corners;
    if (corners == null || _isProcessing) return;
    setState(() {
      _isProcessing = true;
      _error = null;
    });
    try {
      Uint8List? processed = _filterPreviews?[_selectedFilter];
      if (processed == null) {
        final warped = _warpedForPreview ?? warpDocument(widget.originalBytes, corners);
        processed = applyFilter(warped, _selectedFilter);
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        ScannedPage(
          originalBytes: widget.originalBytes,
          corners: corners,
          filter: _selectedFilter,
          processedBytes: processed,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _error = 'Could not process this page: $e';
      });
    }
  }

  bool get _isEditingExistingPage => widget.initialCorners != null;

  @override
  Widget build(BuildContext context) {
    final imageSize = _imageSize;
    final corners = _corners;
    final ready = imageSize != null && corners != null;

    return Scaffold(
      appBar: AppBar(title: Text(_appBarTitle)),
      body: !ready
          ? Center(
              child: _error != null
                  ? _InitErrorView(message: _error!)
                  : const CircularProgressIndicator(),
            )
          : _step == _Step.corners
              ? _buildCornersStep(context, imageSize, corners)
              : _buildFilterStep(context),
    );
  }

  String get _appBarTitle {
    if (_step == _Step.filter) return 'Preview';
    return _isEditingExistingPage ? 'Edit page' : 'Adjust corners';
  }

  Widget _buildCornersStep(BuildContext context, Size imageSize, List<Offset> corners) {
    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CornerOverlay(
              imageBytes: widget.originalBytes,
              imageSize: imageSize,
              corners: corners,
              onChanged: (c) {
                setState(() => _corners = c);
                _updatePreviews();
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

  Widget _buildFilterStep(BuildContext context) {
    final previewBytes = _filterPreviews?[_selectedFilter];
    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: previewBytes != null
                ? Image.memory(previewBytes, fit: BoxFit.contain)
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final filter in PageFilter.values) _filterChip(context, filter),
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
                    onPressed: _isProcessing ? null : () => setState(() => _step = _Step.corners),
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
        onTap: () => setState(() => _selectedFilter = filter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: selected ? primary : Colors.transparent, width: 2),
              ),
              child: previewBytes != null
                  ? Image.memory(previewBytes, fit: BoxFit.cover)
                  : ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: _isGeneratingPreviews
                          ? const Center(
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
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
          Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
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
