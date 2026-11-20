import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/layout_stability.dart';

class _Toggle extends StatefulWidget {
  const _Toggle({required this.reserveSpace});

  final bool reserveSpace;

  @override
  State<_Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<_Toggle> {
  var show = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        if (widget.reserveSpace)
          Visibility(
            visible: show,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: const SizedBox(height: 40, child: Text('status')),
          )
        else if (show)
          const SizedBox(height: 40, child: Text('status')),
        TextButton(
          key: const Key('anchor'),
          onPressed: () => setState(() => show = !show),
          child: const Text('toggle'),
        ),
      ],
    ),
  );
}

void main() {
  testLayoutMatrix(
    'reserved space keeps the anchor in place',
    (tester, layoutCase) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: withTextScale(layoutCase.textScale),
          home: const _Toggle(reserveSpace: true),
        ),
      );
      await expectStableRects(
        tester,
        {'anchor': find.byKey(const Key('anchor'))},
        () async {
          await tester.tap(find.byKey(const Key('anchor')));
          await tester.pump();
        },
      );
    },
    cases: [LayoutCase(const Size(320, 568), 2.0)],
  );

  testWidgets('an inserted row is reported as a layout shift', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _Toggle(reserveSpace: false)),
    );
    final anchor = find.byKey(const Key('anchor'));
    final before = captureRects(tester, {'anchor': anchor});
    await tester.tap(anchor);
    await tester.pump();
    expect(captureRects(tester, {'anchor': anchor}), isNot(equals(before)));
    TestFailure? failure;
    try {
      await expectStableRects(tester, {'anchor': anchor}, () async {
        await tester.tap(anchor);
        await tester.pump();
      });
    } on TestFailure catch (error) {
      failure = error;
    }
    expect(failure?.message, contains('"anchor" moved'));
  });
}
