import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        listEquals,
        visibleForTesting;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';

// Keep the channel contract synchronized with MainActivity.kt.
const _channel = MethodChannel('com.fosscanner.app/gesture_exclusion');

/// Android honours at most this much exclusion height per screen edge, in
/// logical pixels; anything beyond it is ignored by the system.
const maxGestureExclusionPerEdge = 200.0;

/// Returns the parts of [regions] that fall inside the left and right
/// system back-gesture zones described by [gestureInsets], so drags that
/// start there reach the app instead of triggering Back.
///
/// Only the overlap with an edge zone is excluded: the rest of the edge keeps
/// working as Back. Each edge is capped at [maxPerEdge] of total height, in
/// [regions] order, matching Android's limit. All values share one unit
/// (logical or physical pixels).
List<Rect> gestureExclusionRects(
  Iterable<Rect> regions, {
  required Size screen,
  required EdgeInsets gestureInsets,
  double maxPerEdge = maxGestureExclusionPerEdge,
}) {
  final zones = [
    if (gestureInsets.left > 0)
      Rect.fromLTRB(0, 0, gestureInsets.left, screen.height),
    if (gestureInsets.right > 0)
      Rect.fromLTRB(
        screen.width - gestureInsets.right,
        0,
        screen.width,
        screen.height,
      ),
  ];
  final result = <Rect>[];
  for (final zone in zones) {
    var remaining = maxPerEdge;
    for (final region in regions) {
      if (remaining <= 0) break;
      if (!region.isFinite || !region.overlaps(zone)) continue;
      final overlap = region.intersect(zone);
      if (overlap.isEmpty) continue;
      final height = math.min(overlap.height, remaining);
      result.add(
        Rect.fromLTWH(overlap.left, overlap.top, overlap.width, height),
      );
      remaining -= height;
    }
  }
  return result;
}

/// Sends the rects of every mounted [GestureExclusionRegion] to Android's
/// `View.setSystemGestureExclusionRects`, once per frame and only when they
/// change.
class GestureExclusionRegistry {
  GestureExclusionRegistry._();

  static final instance = GestureExclusionRegistry._();

  final _boxes = <RenderBox>{};
  bool _scheduled = false;
  List<int> _lastSent = const [];

  /// Replaces the platform call, for tests.
  @visibleForTesting
  Future<void> Function(List<int> rects)? sendOverride;

  @visibleForTesting
  void resetForTesting() {
    _boxes.clear();
    _lastSent = const [];
  }

  bool get _isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _add(RenderBox box) {
    if (!_isSupported) return;
    _boxes.add(box);
    _schedule();
  }

  void _remove(RenderBox box) {
    if (_boxes.remove(box)) _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _flush();
      // Regions can move without rebuilding (sheets, route transitions):
      // re-check after every frame while any are mounted.
      if (_boxes.isNotEmpty) _schedule();
    });
  }

  void _flush() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final ratio = view.devicePixelRatio;
    final regions = [
      for (final box in _boxes)
        if (box.attached && box.hasSize)
          MatrixUtils.transformRect(
            box.getTransformTo(null),
            Offset.zero & box.size,
          ),
    ];
    final insets = view.systemGestureInsets;
    final rects = gestureExclusionRects(
      regions,
      screen: view.physicalSize / ratio,
      gestureInsets: EdgeInsets.fromLTRB(
        insets.left / ratio,
        insets.top / ratio,
        insets.right / ratio,
        insets.bottom / ratio,
      ),
    );
    final physical = [
      for (final rect in rects) ...[
        (rect.left * ratio).floor(),
        (rect.top * ratio).floor(),
        (rect.right * ratio).ceil(),
        (rect.bottom * ratio).ceil(),
      ],
    ];
    if (listEquals(physical, _lastSent)) return;
    _lastSent = physical;
    final send =
        sendOverride ??
        (rects) =>
            _channel.invokeMethod<void>('setExclusionRects', {'rects': rects});
    // Best effort: a missing handler (older embedder, tests) changes nothing.
    send(physical).catchError((Object _) {});
  }
}

/// Keeps drags that start on [child] from triggering the system Back gesture
/// when [child] reaches into a screen-edge gesture zone (Android 10+ gesture
/// navigation). Use it only for small drag targets such as handles and
/// slider tracks; Android caps the excluded height per edge.
class GestureExclusionRegion extends SingleChildRenderObjectWidget {
  const GestureExclusionRegion({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGestureExclusionRegion();
}

class _RenderGestureExclusionRegion extends RenderProxyBox {
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    GestureExclusionRegistry.instance._add(this);
  }

  @override
  void detach() {
    GestureExclusionRegistry.instance._remove(this);
    super.detach();
  }
}
