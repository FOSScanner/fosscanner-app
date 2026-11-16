import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

const _corners = [Offset.zero, Offset(99, 0), Offset(99, 99), Offset(0, 99)];

void main() {
  for (final index in [0, 1, 2, 3]) {
    testWidgets('outer visible edge of corner $index can start a drag', (
      tester,
    ) async {
      final data = await rootBundle.load('assets/icon/icon.png');
      List<Offset>? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: CornerOverlay(
                imageBytes: data.buffer.asUint8List(),
                imageSize: const Size(100, 100),
                corners: _corners,
                onChanged: (value) => changed = value,
              ),
            ),
          ),
        ),
      );
      final image = tester.getRect(find.byType(Image));
      final center = image.topLeft + _corners[index] * (image.width / 100);
      final outward = const [
        Offset(-8, -8),
        Offset(8, -8),
        Offset(8, 8),
        Offset(-8, 8),
      ][index];
      final delta = -outward * 5;
      await tester.dragFrom(center + outward, delta);
      await tester.pump();
      expect(changed, isNotNull);
      expect(changed![index], isNot(_corners[index]));
      for (var i = 0; i < 4; i++) {
        if (i != index) expect(changed![i], _corners[i]);
      }
    });
  }

  testWidgets('dragging a corner does not also scroll its parent', (
    tester,
  ) async {
    final data = await rootBundle.load('assets/icon/icon.png');
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    List<Offset>? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: CornerOverlay(
                      imageBytes: data.buffer.asUint8List(),
                      imageSize: const Size(100, 100),
                      corners: _corners,
                      onChanged: (value) => changed = value,
                    ),
                  ),
                  const SizedBox(height: 600),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final image = tester.getRect(find.byType(Image));
    final center = image.topLeft + _corners[2] * (image.width / 100);
    await tester.dragFrom(center, const Offset(-40, -80));
    await tester.pumpAndSettle();
    expect(changed, isNotNull);
    expect(scroll.offset, 0);
    // A gesture away from the handles must still scroll normally.
    await tester.dragFrom(
      tester.getRect(find.byType(CornerOverlay)).center,
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
  });
}
