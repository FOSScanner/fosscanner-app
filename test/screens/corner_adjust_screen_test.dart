import 'dart:ui' show PointerDeviceKind, SemanticsAction;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

Future<Uint8List> _iconBytes() async {
  final data = await rootBundle.load('assets/icon/icon.png');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

const _cornerSemanticLabels = [
  'Top-left corner',
  'Top-right corner',
  'Bottom-right corner',
  'Bottom-left corner',
];
const _standardCorners = [
  Offset(10, 10),
  Offset(90, 10),
  Offset(90, 90),
  Offset(10, 90),
];
const _smallBoundaryCorners = [
  Offset.zero,
  Offset(19, 0),
  Offset(19, 19),
  Offset(0, 19),
];
const _boundaryCorners = [
  Offset.zero,
  Offset(99, 0),
  Offset(99, 99),
  Offset(0, 99),
];

Widget _overlayApp({
  required Uint8List imageBytes,
  required ValueChanged<List<Offset>> onChanged,
  Size containerSize = const Size(200, 200),
  Size imageSize = const Size(100, 100),
  List<Offset> corners = _standardCorners,
  bool centered = true,
}) {
  final overlay = SizedBox(
    width: containerSize.width,
    height: containerSize.height,
    child: CornerOverlay(
      imageBytes: imageBytes,
      imageSize: imageSize,
      corners: corners,
      onChanged: onChanged,
    ),
  );
  return MaterialApp(home: centered ? Center(child: overlay) : overlay);
}

void main() {
  testWidgets('shows a loading state while the photo is being decoded', (
    tester,
  ) async {
    // Genuinely-invalid bytes are intentional: this only exercises the
    // widget's build before/without the async _initialize() chain
    // resolving successfully. Real image decoding via
    // ui.instantiateImageCodec is known to hang forever under
    // flutter_test's fake-time test binding even though it works fine in
    // the real app (verified separately) — full pipeline correctness is
    // covered by the Phase 0 spike script and on-device testing instead.
    final bytes = Uint8List.fromList(const [0, 1, 2, 3]);

    await tester.pumpWidget(
      MaterialApp(home: CornerAdjustScreen(originalBytes: bytes)),
    );

    expect(find.text('Adjust corners'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets(
    'shows an error state (not an infinite spinner) when decoding fails',
    (tester) async {
      final bytes = Uint8List.fromList(const [0, 1, 2, 3]);

      await tester.pumpWidget(
        MaterialApp(home: CornerAdjustScreen(originalBytes: bytes)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not read this photo'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'corner handles stay on valid pixels and meet the minimum tap target',
    (tester) async {
      final imageBytes = await _iconBytes();
      List<Offset>? changed;
      await tester.pumpWidget(
        _overlayApp(
          imageBytes: imageBytes,
          onChanged: (corners) => changed = corners,
        ),
      );

      final firstHandle = find.byKey(const ValueKey('corner-handle-0'));
      expect(tester.getSize(firstHandle), const Size.square(48));

      await tester.drag(firstHandle, const Offset(400, 400));
      await tester.pump();

      expect(changed, isNotNull);
      expect(changed!.first, const Offset(99, 99));
    },
  );

  testWidgets('a stationary tap does not commit unchanged corners', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('corner-handle-0')));
    await tester.pump();

    expect(changed, isNull);
  });

  testWidgets('non-primary mouse buttons do not move corners', (tester) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
      ),
    );

    final handle = find.byKey(const ValueKey('corner-handle-0'));
    final originalCenter = tester.getCenter(handle);
    final gesture = await tester.startGesture(
      originalCenter,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.moveBy(const Offset(30, 20));
    await gesture.up();
    await tester.pump();

    expect(changed, isNull);
    expect(tester.getCenter(handle), originalCenter);
  });

  testWidgets('small primary mouse drags remain precise', (tester) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('corner-handle-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(10, 0));
    await gesture.up();
    await tester.pump();

    expect(changed, isNotNull);
    expect(changed!.first, const Offset(15, 10));
  });

  testWidgets('a cancelled corner drag restores the committed position', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
        centered: false,
      ),
    );

    final firstHandle = find.byKey(const ValueKey('corner-handle-0'));
    final originalCenter = tester.getCenter(firstHandle);
    final gesture = await tester.startGesture(originalCenter);
    await gesture.moveBy(const Offset(40, 30));
    await tester.pump();
    expect(tester.getCenter(firstHandle), isNot(originalCenter));

    await gesture.cancel();
    await tester.pump();

    expect(changed, isNull);
    expect(tester.getCenter(firstHandle), originalCenter);
  });

  testWidgets('a secondary pointer cancellation preserves the active drag', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
        containerSize: const Size(200, 20),
        imageSize: const Size.square(20),
        corners: _smallBoundaryCorners,
      ),
    );

    final overlay = tester.getRect(find.byType(CornerOverlay));
    final primary = await tester.startGesture(
      overlay.topLeft + const Offset(90, 1),
      pointer: 1,
    );
    await primary.moveBy(const Offset(30, 0));
    final secondary = await tester.startGesture(overlay.center, pointer: 2);
    await secondary.cancel();
    await primary.moveBy(const Offset(10, 5));
    await primary.up();
    await tester.pump();

    expect(changed, isNotNull);
  });

  testWidgets('only the pointer that starts a corner drag can cancel it', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
      ),
    );

    final overlay = tester.getRect(find.byType(CornerOverlay));
    final originalCenter = tester.getCenter(
      find.byKey(const ValueKey('corner-handle-0')),
    );
    final idlePointer = await tester.startGesture(overlay.center, pointer: 1);
    final draggingPointer = await tester.startGesture(
      originalCenter,
      pointer: 2,
    );
    await draggingPointer.moveBy(const Offset(30, 20));
    await tester.pump();
    expect(
      tester.getCenter(find.byKey(const ValueKey('corner-handle-0'))),
      isNot(originalCenter),
    );

    await draggingPointer.cancel();
    await idlePointer.up();
    await tester.pump();

    expect(changed, isNull);
    expect(
      tester.getCenter(find.byKey(const ValueKey('corner-handle-0'))),
      originalCenter,
    );
  });

  testWidgets('tiny layouts route a visible corner to the matching handle', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
        containerSize: const Size.square(20),
        imageSize: const Size.square(20),
        corners: _smallBoundaryCorners,
      ),
    );

    final overlay = tester.getRect(find.byType(CornerOverlay));
    await tester.dragFrom(
      overlay.topLeft + const Offset(1, 1),
      const Offset(25, 25),
    );
    await tester.pump();

    expect(changed, isNotNull);
    expect(changed!.first, const Offset(19, 19));
    expect(changed![3], const Offset(0, 19));
  });

  testWidgets('letterboxed layouts route gestures to the nearest corner', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
        containerSize: const Size(200, 20),
        imageSize: const Size.square(20),
        corners: _smallBoundaryCorners,
      ),
    );

    final overlay = tester.getRect(find.byType(CornerOverlay));
    await tester.dragFrom(
      overlay.topLeft + const Offset(90, 1),
      const Offset(25, 25),
    );
    await tester.pump();

    expect(changed, isNotNull);
    expect(changed!.first, const Offset(19, 19));
    expect(changed![1], const Offset(19, 0));
  });

  testWidgets('letterboxed semantic corner targets do not overlap', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final imageBytes = await _iconBytes();
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (_) {},
        containerSize: const Size(200, 20),
        imageSize: const Size.square(20),
        corners: _smallBoundaryCorners,
      ),
    );

    expect(find.bySemanticsLabel('Document corners'), findsOneWidget);
    expect(find.bySemanticsLabel('Top-left corner'), findsNothing);
    final combined = tester.getSemantics(
      find.bySemanticsLabel('Document corners'),
    );
    expect(combined.getSemanticsData().customSemanticsActionIds, hasLength(16));
    semantics.dispose();
  });

  testWidgets('diagonal semantic corner targets do not overlap', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final imageBytes = await _iconBytes();
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (_) {},
        containerSize: const Size.square(100),
        corners: const [
          Offset(50, 50),
          Offset(80, 20),
          Offset(55, 55),
          Offset(20, 80),
        ],
      ),
    );

    expect(find.bySemanticsLabel('Document corners'), findsOneWidget);
    expect(find.bySemanticsLabel('Top-left corner'), findsNothing);
    semantics.dispose();
  });

  testWidgets('crossed corners keep discoverable semantic targets', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final imageBytes = await _iconBytes();
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (_) {},
        containerSize: const Size.square(100),
        corners: const [
          Offset(90, 10),
          Offset(10, 10),
          Offset(90, 90),
          Offset(10, 90),
        ],
      ),
    );

    expect(find.bySemanticsLabel('Document corners'), findsNothing);
    final overlay = tester.getRect(find.byType(CornerOverlay));
    const expectedPositions = [
      Offset(90, 10),
      Offset(10, 10),
      Offset(90, 90),
      Offset(10, 90),
    ];
    for (var i = 0; i < 4; i++) {
      final semanticRect = tester.getRect(
        find.bySemanticsLabel(_cornerSemanticLabels[i]),
      );
      expect(
        semanticRect.contains(overlay.topLeft + expectedPositions[i]),
        isTrue,
        reason: 'corner $i semantics detached from its visible handle',
      );
    }
    semantics.dispose();
  });

  testWidgets('legacy inclusive corners are normalized and propagated', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
        containerSize: const Size.square(100),
        corners: const [
          Offset.zero,
          Offset(100, 0),
          Offset(100, 100),
          Offset(0, 100),
        ],
        centered: false,
      ),
    );
    await tester.pump();

    expect(changed, const [
      Offset.zero,
      Offset(99, 0),
      Offset(99, 99),
      Offset(0, 99),
    ]);
  });

  testWidgets('the full clamped boundary target remains operable', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    List<Offset>? changed;
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
        containerSize: const Size.square(100),
        corners: _boundaryCorners,
      ),
    );

    final overlay = tester.getRect(find.byType(CornerOverlay));
    await tester.dragFrom(
      overlay.topLeft + const Offset(40, 40),
      const Offset(20, 0),
    );
    await tester.pump();

    expect(changed, isNotNull);
    expect(changed!.first, const Offset(20, 0));
  });

  testWidgets('all boundary corners retain full 48 pixel hit regions', (
    tester,
  ) async {
    final imageBytes = await _iconBytes();
    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (_) {},
        containerSize: const Size.square(100),
        corners: _boundaryCorners,
      ),
    );

    final overlayRect = tester.getRect(find.byType(CornerOverlay));
    for (var i = 0; i < 4; i++) {
      final rect = tester.getRect(find.byKey(ValueKey('corner-handle-$i')));
      expect(rect.size, const Size.square(48));
      expect(rect.left, greaterThanOrEqualTo(overlayRect.left));
      expect(rect.top, greaterThanOrEqualTo(overlayRect.top));
      expect(rect.right, lessThanOrEqualTo(overlayRect.right));
      expect(rect.bottom, lessThanOrEqualTo(overlayRect.bottom));
    }
  });

  testWidgets('corner handles expose operable accessibility actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final imageBytes = await _iconBytes();
    List<Offset>? changed;

    await tester.pumpWidget(
      _overlayApp(
        imageBytes: imageBytes,
        onChanged: (corners) => changed = corners,
        centered: false,
      ),
    );

    expect(find.bySemanticsLabel('Top-left corner'), findsOneWidget);
    expect(find.bySemanticsLabel('Top-right corner'), findsOneWidget);
    expect(find.bySemanticsLabel('Bottom-right corner'), findsOneWidget);
    expect(find.bySemanticsLabel('Bottom-left corner'), findsOneWidget);

    final topLeft = tester.getSemantics(
      find.bySemanticsLabel('Top-left corner'),
    );
    expect(topLeft.getSemanticsData().customSemanticsActionIds, hasLength(4));
    expect(
      topLeft.getSemanticsData().hasAction(SemanticsAction.customAction),
      isTrue,
    );

    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      topLeft.id,
      SemanticsAction.customAction,
      topLeft.getSemanticsData().customSemanticsActionIds!.first,
    );
    await tester.pump();
    expect(changed, isNotNull);
    expect(changed!.first, isNot(const Offset(10, 10)));
    semantics.dispose();
  });
}
