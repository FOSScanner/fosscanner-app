import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show computeHitSlop, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

const _cornerLabels = [
  'Top-left corner',
  'Top-right corner',
  'Bottom-right corner',
  'Bottom-left corner',
];
const _moveLabels = ['left', 'right', 'up', 'down'];
const _moveOffsets = [Offset(-1, 0), Offset(1, 0), Offset(0, -1), Offset(0, 1)];

/// Shows a captured photo with a draggable quad overlay over the document
/// corners. [corners] and [onChanged] are in the *image's* pixel space
/// (top-left, top-right, bottom-right, bottom-left) — this widget only
/// handles the display-space <-> image-space mapping internally, so the
/// caller never has to think about how the image happens to be scaled on
/// screen.
///
/// Live visual feedback while dragging is handled entirely inside this
/// widget via local state — [onChanged] fires once, when a drag ends, not
/// on every pointer move. Firing it every frame used to make the caller
/// (a full screen, including the image and filter previews) rebuild 60+
/// times per second during a drag, which is what caused visible stutter.
class CornerOverlay extends StatefulWidget {
  const CornerOverlay({
    super.key,
    required this.imageBytes,
    required this.imageSize,
    required this.corners,
    required this.onChanged,
  });

  final Uint8List imageBytes;
  final Size imageSize;
  final List<Offset> corners;
  final ValueChanged<List<Offset>> onChanged;

  @override
  State<CornerOverlay> createState() => _CornerOverlayState();
}

class _CornerOverlayState extends State<CornerOverlay> {
  late List<Offset> _liveCorners;
  int? _draggingIndex;
  int? _pendingIndex;
  int? _activePointer;
  Offset? _pointerDownPosition;
  Offset? _cornerAtPointerDown;

  @override
  void initState() {
    super.initState();
    _liveCorners = _normalizeCorners(widget.corners);
    _propagateNormalization(widget.corners, _liveCorners);
  }

  @override
  void didUpdateWidget(CornerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only resync from the parent when it hands us a genuinely different
    // list (e.g. detection just finished) — not after our own onChanged
    // round-trips the same list back to us, which would be a no-op but is
    // worth avoiding for clarity.
    if (!identical(widget.corners, oldWidget.corners)) {
      final normalized = _normalizeCorners(widget.corners);
      _liveCorners = normalized;
      _propagateNormalization(widget.corners, normalized);
    }
  }

  List<Offset> _normalizeCorners(List<Offset> corners) => [
    for (final corner in corners) _clampToImage(corner),
  ];

  void _propagateNormalization(List<Offset> incoming, List<Offset> normalized) {
    if (listEquals(incoming, normalized)) return;
    final value = [...normalized];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(value);
    });
  }

  Offset _clampToImage(Offset p) {
    // Pixel coordinates end at width/height - 1. Allowing a handle to land at
    // width or height makes perspective correction sample outside the photo,
    // which can introduce a dark border along the exported page.
    return Offset(
      p.dx.clamp(0.0, widget.imageSize.width - 1),
      p.dy.clamp(0.0, widget.imageSize.height - 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    assert(_liveCorners.length == 4);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = applyBoxFit(
          BoxFit.contain,
          widget.imageSize,
          constraints.biggest,
        );
        final displaySize = fitted.destination;
        final scale = displaySize.width / widget.imageSize.width;
        final offsetX = (constraints.maxWidth - displaySize.width) / 2;
        final offsetY = (constraints.maxHeight - displaySize.height) / 2;

        Offset toDisplay(Offset p) =>
            Offset(p.dx * scale + offsetX, p.dy * scale + offsetY);

        final displayCorners = _liveCorners.map(toDisplay).toList();
        final handleTargets = [
          for (final corner in displayCorners)
            _handleTargetRect(corner, constraints.biggest),
        ];
        final hasOverlappingTargets = _hasOverlaps(handleTargets);

        int? nearestCorner(Offset position) {
          int? nearestIndex;
          var nearestDistance = double.infinity;
          for (var i = 0; i < displayCorners.length; i++) {
            final target = _handleTargetRect(
              displayCorners[i],
              constraints.biggest,
            );
            if (!target.contains(position)) continue;
            final distance = (displayCorners[i] - position).distance;
            if (distance < nearestDistance) {
              nearestDistance = distance;
              nearestIndex = i;
            }
          }
          return nearestIndex;
        }

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (_activePointer != null || event.buttons & kPrimaryButton == 0) {
              return;
            }
            final index = nearestCorner(event.localPosition);
            if (index == null) return;
            _activePointer = event.pointer;
            _pendingIndex = index;
            _pointerDownPosition = event.localPosition;
            _cornerAtPointerDown = _liveCorners[index];
          },
          onPointerMove: (event) {
            if (_activePointer != event.pointer || scale <= 0) return;
            final index = _pendingIndex;
            final downPosition = _pointerDownPosition;
            final initialCorner = _cornerAtPointerDown;
            if (index == null ||
                downPosition == null ||
                initialCorner == null) {
              return;
            }
            final totalDelta = event.localPosition - downPosition;
            if (_draggingIndex == null &&
                totalDelta.distance <= computeHitSlop(event.kind, null)) {
              return;
            }
            setState(() {
              _draggingIndex = index;
              _liveCorners = [..._liveCorners];
              _liveCorners[index] = _clampToImage(
                initialCorner + totalDelta / scale,
              );
            });
          },
          onPointerUp: (event) {
            if (_activePointer != event.pointer) return;
            final shouldCommit = _draggingIndex != null;
            _clearPointerState();
            if (shouldCommit) {
              setState(() => _draggingIndex = null);
              widget.onChanged([..._liveCorners]);
            }
          },
          onPointerCancel: (event) {
            if (_activePointer == event.pointer) _cancelDrag();
          },
          child: Stack(
            children: [
              Positioned(
                left: offsetX,
                top: offsetY,
                width: displaySize.width,
                height: displaySize.height,
                // Isolates the (potentially large) photo's paint layer from
                // the quad/handles repainting every drag frame.
                child: RepaintBoundary(
                  child: Image.memory(widget.imageBytes, fit: BoxFit.fill),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _QuadPainter(displayCorners, context),
                ),
              ),
              for (var i = 0; i < 4; i++)
                _cornerHandle(
                  index: i,
                  displayPos: displayCorners[i],
                  targetRect: handleTargets[i],
                  exposeSemantics: !hasOverlappingTargets,
                ),
              if (hasOverlappingTargets)
                _combinedCornerSemantics(handleTargets),
            ],
          ),
        );
      },
    );
  }

  void _clearPointerState() {
    _activePointer = null;
    _pendingIndex = null;
    _pointerDownPosition = null;
    _cornerAtPointerDown = null;
  }

  void _cancelDrag() {
    setState(() {
      _clearPointerState();
      _draggingIndex = null;
      _liveCorners = _normalizeCorners(widget.corners);
    });
  }

  void _moveCornerForAccessibility(int index, Offset delta) {
    final next = [..._liveCorners];
    next[index] = _clampToImage(next[index] + delta);
    setState(() => _liveCorners = next);
    widget.onChanged(next);
  }

  Rect _handleTargetRect(Offset displayPos, Size containerSize) {
    const preferredTouchTargetSize = 48.0;
    final targetWidth = math.min(
      preferredTouchTargetSize,
      math.max(1.0, containerSize.width / 2),
    );
    final targetHeight = math.min(
      preferredTouchTargetSize,
      math.max(1.0, containerSize.height / 2),
    );
    double targetOrigin(double position, double extent, double targetExtent) =>
        (position - targetExtent / 2)
            .clamp(0.0, math.max(0.0, extent - targetExtent))
            .toDouble();

    return Rect.fromLTWH(
      targetOrigin(displayPos.dx, containerSize.width, targetWidth),
      targetOrigin(displayPos.dy, containerSize.height, targetHeight),
      targetWidth,
      targetHeight,
    );
  }

  bool _hasOverlaps(List<Rect> targets) {
    for (var i = 0; i < targets.length; i++) {
      for (var j = i + 1; j < targets.length; j++) {
        if (targets[i].overlaps(targets[j])) return true;
      }
    }
    return false;
  }

  double get _semanticStep => math.max(
    1.0,
    math.min(widget.imageSize.width, widget.imageSize.height) / 100,
  );

  Map<CustomSemanticsAction, VoidCallback> _semanticActions(
    Iterable<int> cornerIndexes, {
    required bool includeCornerName,
  }) => {
    for (final cornerIndex in cornerIndexes)
      for (var moveIndex = 0; moveIndex < _moveLabels.length; moveIndex++)
        CustomSemanticsAction(
          label: includeCornerName
              ? '${_cornerLabels[cornerIndex]}: move ${_moveLabels[moveIndex]}'
              : 'Move ${_moveLabels[moveIndex]}',
        ): () => _moveCornerForAccessibility(
          cornerIndex,
          _moveOffsets[moveIndex] * _semanticStep,
        ),
  };

  Widget _combinedCornerSemantics(List<Rect> targets) {
    final rect = targets.reduce((a, b) => a.expandToInclude(b));
    final values = [
      for (var i = 0; i < _liveCorners.length; i++)
        '${_cornerLabels[i]} ${_liveCorners[i].dx.round()}, '
            '${_liveCorners[i].dy.round()} pixels',
    ];
    return Positioned.fromRect(
      rect: rect,
      child: Semantics(
        label: 'Document corners',
        value: values.join('; '),
        hint: 'Use the named directional actions to adjust each corner',
        customSemanticsActions: _semanticActions(const [
          0,
          1,
          2,
          3,
        ], includeCornerName: true),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _cornerHandle({
    required int index,
    required Offset displayPos,
    required Rect targetRect,
    required bool exposeSemantics,
  }) {
    final isDragging = _draggingIndex == index;
    final visibleHandleSize = isDragging ? 40.0 : 32.0;
    final localVisualCenter = displayPos - targetRect.topLeft;
    final visual = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: localVisualCenter.dx - visibleHandleSize / 2,
          top: localVisualCenter.dy - visibleHandleSize / 2,
          child: SizedBox.square(
            dimension: visibleHandleSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 4),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    final child = exposeSemantics
        ? Semantics(
            label: _cornerLabels[index],
            value:
                '${_liveCorners[index].dx.round()}, '
                '${_liveCorners[index].dy.round()} pixels',
            hint: 'Use the directional actions to adjust this corner',
            customSemanticsActions: _semanticActions([
              index,
            ], includeCornerName: false),
            child: visual,
          )
        : ExcludeSemantics(child: visual);

    return Positioned.fromRect(
      rect: targetRect,
      child: KeyedSubtree(key: ValueKey('corner-handle-$index'), child: child),
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.corners, this.context);

  final List<Offset> corners;
  final BuildContext context;

  @override
  void paint(Canvas canvas, Size size) {
    final primary = Theme.of(context).colorScheme.primary;
    final path = Path()..addPolygon(corners, true);
    canvas.drawPath(path, Paint()..color = primary.withValues(alpha: 0.2));
    canvas.drawPath(
      path,
      Paint()
        ..color = primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) => true;
}
