import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Displays the saved result without rerunning any image processing.
///
/// Pinch to zoom, or double-tap to zoom in on a point and double-tap again
/// to fit the page.
class PagePreviewScreen extends StatefulWidget {
  const PagePreviewScreen({
    super.key,
    required this.imageBytes,
    required this.pageNumber,
  });

  final Uint8List imageBytes;
  final int pageNumber;

  /// The zoom a double-tap applies to a fitted page.
  static const doubleTapScale = 2.5;

  @override
  State<PagePreviewScreen> createState() => _PagePreviewScreenState();
}

class _PagePreviewScreenState extends State<PagePreviewScreen>
    with SingleTickerProviderStateMixin {
  final _transformation = TransformationController();
  late final AnimationController _zoomAnimation;
  Animation<Matrix4>? _zoom;
  Offset _doubleTapPosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoomAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(_applyZoomStep);
  }

  @override
  void dispose() {
    _zoomAnimation.dispose();
    _transformation.dispose();
    super.dispose();
  }

  void _applyZoomStep() {
    final zoom = _zoom;
    if (zoom != null) _transformation.value = zoom.value;
  }

  void _toggleZoom() {
    final Matrix4 target;
    if (_transformation.value.getMaxScaleOnAxis() > 1.01) {
      target = Matrix4.identity();
    } else {
      // Keep the tapped point under the finger.
      const scale = PagePreviewScreen.doubleTapScale;
      final focus = _doubleTapPosition;
      target = Matrix4.identity()
        ..translateByDouble(
          -focus.dx * (scale - 1),
          -focus.dy * (scale - 1),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, 1, 1);
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _zoomAnimation.stop();
      _transformation.value = target;
      return;
    }
    _zoom = Matrix4Tween(
      begin: _transformation.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeInOut));
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Page ${widget.pageNumber}'),
      actions: [
        IconButton(
          tooltip: 'Edit page',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () {
            if (ModalRoute.of(context)?.isCurrent ?? false) {
              Navigator.of(context).pop(true);
            }
          },
        ),
      ],
    ),
    body: SafeArea(
      child: GestureDetector(
        onDoubleTapDown: (details) =>
            _doubleTapPosition = details.localPosition,
        onDoubleTap: _toggleZoom,
        child: InteractiveViewer(
          transformationController: _transformation,
          minScale: 1,
          maxScale: 4,
          // A pinch takes over from a running double-tap zoom.
          onInteractionStart: (_) => _zoomAnimation.stop(),
          child: SizedBox.expand(
            child: Image(
              image: ResizeImage(
                MemoryImage(widget.imageBytes),
                width: 2048,
                height: 2048,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.contain,
              semanticLabel: 'Preview of page ${widget.pageNumber}',
              errorBuilder: (_, _, _) =>
                  const Center(child: Text('Could not display this page.')),
            ),
          ),
        ),
      ),
    ),
  );
}
