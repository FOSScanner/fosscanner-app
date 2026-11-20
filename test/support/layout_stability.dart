import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Logical viewport sizes; DPR changes physical pixels, not logical dimensions.
class LayoutConfiguration {
  const LayoutConfiguration(
    this.name,
    this.size, {
    this.density = 1,
    this.textScaler = TextScaler.noScaling,
    this.brightness = Brightness.light,
    this.padding = const FakeViewPadding(),
  });

  final String name;
  final Size size;
  final double density;
  final TextScaler textScaler;
  final Brightness brightness;
  final FakeViewPadding padding;

  void apply(WidgetTester tester) {
    tester.view.devicePixelRatio = density;
    tester.view.physicalSize = size * density;
    tester.view.padding = FakeViewPadding(
      left: padding.left * density,
      top: padding.top * density,
      right: padding.right * density,
      bottom: padding.bottom * density,
    );
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
  }

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Roboto',
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: brightness,
      ),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: child,
  );
}

/// A deterministic nonlinear fixture, not an emulation of an OS scaling curve.
class NonlinearTestScaler extends TextScaler {
  const NonlinearTestScaler();

  @override
  double scale(double fontSize) =>
      fontSize <= 16 ? fontSize * 2 : fontSize + 16;

  @override
  double get textScaleFactor => 2;
}

const responsiveLayouts = [
  LayoutConfiguration(
    'small_large_text',
    Size(320, 568),
    textScaler: TextScaler.linear(2),
  ),
  LayoutConfiguration('phone', Size(390, 844), density: 3),
  LayoutConfiguration(
    'landscape_dark',
    Size(640, 300),
    density: 2,
    brightness: Brightness.dark,
  ),
  LayoutConfiguration(
    'tablet',
    Size(800, 1280),
    density: 1.5,
    textScaler: TextScaler.linear(1.3),
  ),
  LayoutConfiguration(
    'narrow_nonlinear',
    Size(240, 640),
    textScaler: NonlinearTestScaler(),
    brightness: Brightness.dark,
  ),
];

/// Bundle the exact fonts from the pinned Flutter SDK, without host font lookup.
Future<void> loadGoldenFonts() async {
  final configFile = File('.dart_tool/package_config.json').absolute;
  final config =
      jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  final flutter = (config['packages'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((package) => package['name'] == 'flutter');
  final root = configFile.uri.resolve(flutter['rootUri'] as String);
  final sdk = Directory.fromUri(root).parent.parent.path;
  for (final font in [
    (family: 'Roboto', file: 'Roboto-Regular.ttf'),
    (family: 'MaterialIcons', file: 'MaterialIcons-Regular.otf'),
  ]) {
    await (FontLoader(font.family)..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '$sdk/bin/cache/artifacts/material_fonts/${font.file}',
              ).readAsBytes(),
            ),
          ),
        ))
        .load();
  }
}

Future<void> expectStableRects(
  WidgetTester tester,
  List<Finder> anchors,
  Future<void> Function() transition, {
  double tolerance = 0.5,
}) async {
  final before = [for (final anchor in anchors) tester.getRect(anchor)];
  await transition();
  await tester.pump();
  for (var i = 0; i < anchors.length; i++) {
    final after = tester.getRect(anchors[i]);
    expect(after.left, closeTo(before[i].left, tolerance));
    expect(after.top, closeTo(before[i].top, tolerance));
    expect(after.width, closeTo(before[i].width, tolerance));
    expect(after.height, closeTo(before[i].height, tolerance));
  }
}
