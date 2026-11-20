import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

const _corners = [
  Offset(20, 20),
  Offset(80, 20),
  Offset(80, 80),
  Offset(20, 80),
];

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('dims outside the crop and leaves the inside untinted '
        '[${brightness.name}]', (tester) async {
      final data = await rootBundle.load('assets/icon/icon.png');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Center(
            child: SizedBox(
              width: 248,
              height: 248,
              child: CornerOverlay(
                imageBytes: data.buffer.asUint8List(),
                imageSize: const Size(100, 100),
                corners: _corners,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      // 24 px gutter, 2 px per image pixel.
      final painter = find
          .descendant(
            of: find.byType(CornerOverlay),
            matching: find.byType(CustomPaint),
          )
          .first;
      expect(
        painter,
        paints
          ..path(
            color: const Color(0x8C000000),
            includes: const [Offset(30, 30), Offset(124, 40), Offset(220, 220)],
            excludes: const [
              Offset(124, 124),
              Offset(70, 70),
              Offset(170, 170),
              // Outside the image: the canvas background is not dimmed.
              Offset(10, 124),
            ],
          )
          // A hairline around the photo keeps a white page visible.
          ..rect(
            rect: const Rect.fromLTWH(24.5, 24.5, 199, 199),
            color: ThemeData(brightness: brightness).colorScheme.outlineVariant,
            style: PaintingStyle.stroke,
          )
          ..path(style: PaintingStyle.stroke),
      );
      expect(painter, paintsExactlyCountTimes(#drawPath, 2));
    });
  }
}
