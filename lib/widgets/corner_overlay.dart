import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Shows a captured photo with a draggable quad overlay over the document
/// corners. [corners] and [onChanged] are in the *image's* pixel space
/// (top-left, top-right, bottom-right, bottom-left) — this widget only
/// handles the display-space <-> image-space mapping internally, so the
/// caller never has to think about how the image happens to be scaled on
/// screen.
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
  int? _draggingIndex;

  Offset _clampToImage(Offset p) {
    return Offset(
      p.dx.clamp(0.0, widget.imageSize.width),
      p.dy.clamp(0.0, widget.imageSize.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.corners.length == 4);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = applyBoxFit(BoxFit.contain, widget.imageSize, constraints.biggest);
        final displaySize = fitted.destination;
        final scale = displaySize.width / widget.imageSize.width;
        final offsetX = (constraints.maxWidth - displaySize.width) / 2;
        final offsetY = (constraints.maxHeight - displaySize.height) / 2;

        Offset toDisplay(Offset p) => Offset(p.dx * scale + offsetX, p.dy * scale + offsetY);

        final displayCorners = widget.corners.map(toDisplay).toList();

        return Stack(
          children: [
            Positioned(
              left: offsetX,
              top: offsetY,
              width: displaySize.width,
              height: displaySize.height,
              child: Image.memory(widget.imageBytes, fit: BoxFit.fill),
            ),
            Positioned.fill(
              child: CustomPaint(painter: _QuadPainter(displayCorners, context)),
            ),
            for (var i = 0; i < 4; i++)
              _cornerHandle(index: i, displayPos: displayCorners[i], scale: scale),
          ],
        );
      },
    );
  }

  Widget _cornerHandle({required int index, required Offset displayPos, required double scale}) {
    final isDragging = _draggingIndex == index;
    final handleSize = isDragging ? 40.0 : 32.0;
    return Positioned(
      left: displayPos.dx - handleSize / 2,
      top: displayPos.dy - handleSize / 2,
      width: handleSize,
      height: handleSize,
      child: GestureDetector(
        onPanStart: (_) => setState(() => _draggingIndex = index),
        onPanUpdate: (details) {
          final imageDelta = Offset(details.delta.dx / scale, details.delta.dy / scale);
          final updated = [...widget.corners];
          updated[index] = _clampToImage(updated[index] + imageDelta);
          widget.onChanged(updated);
        },
        onPanEnd: (_) => setState(() => _draggingIndex = null),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
          ),
        ),
      ),
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
