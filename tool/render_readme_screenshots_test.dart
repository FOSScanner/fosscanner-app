import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:fosscanner/services/image_metadata.dart' show maxDocumentPages;
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

class _UnreadableDraftStore extends NoOpDraftStore {
  @override
  Future<List<ScannedPage>> load() async => throw const DraftRestoreException();
}

// These renders document UI, not native edge detection or filter quality.
class _PreviewFixture implements CornerAdjustOperations {
  _PreviewFixture(this.bytes);
  final Uint8List bytes;

  @override
  Future<Size> decodeSize(Uint8List bytes) async => const Size(1000, 1400);

  @override
  Future<List<Offset>?> detectCorners(Uint8List bytes) async => null;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List bytes,
    List<Offset> corners,
  ) async => {for (final filter in PageFilter.values) filter: bytes};

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List bytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => bytes;

  @override
  Future<Uint8List> processForExport(
    Uint8List bytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => bytes;
}

Future<Uint8List> _sampleDocument() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  void text(String value, double y, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: size,
          color: const Color(0xff263238),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 840);
    painter.paint(canvas, Offset(80, y));
    painter.dispose();
  }

  canvas.drawRect(
    const Rect.fromLTWH(80, 90, 100, 10),
    Paint()..color = Colors.deepPurple,
  );
  text('Project notes', 140, 62);
  text('DEMO DOCUMENT', 240, 27);
  text('A clear plan for the next steps', 350, 35);
  for (var i = 0; i < 12; i++) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(80, 450 + i * 48, i % 4 == 3 ? 560 : 820, 9),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xffcfd8dc),
    );
  }
  text('Synthetic sample — no personal information', 1220, 24);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1000, 1400);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('render README screens using synthetic documents', (
    tester,
  ) async {
    final originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    addTearDown(() => ImagePickerPlatform.instance = originalPicker);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = previousShadows);

    await tester.runAsync(() async {
      final configFile = File('.dart_tool/package_config.json').absolute;
      final config =
          jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      final packages = config['packages'] as List<dynamic>;
      final flutter = packages.cast<Map<String, dynamic>>().singleWhere(
        (package) => package['name'] == 'flutter',
      );
      final root = configFile.uri.resolve(flutter['rootUri'] as String);
      final sdk = Directory.fromUri(root).parent.parent.path;
      final fonts = '$sdk/bin/cache/artifacts/material_fonts';
      for (final font in [
        (family: 'Roboto', file: 'Roboto-Regular.ttf'),
        (family: 'MaterialIcons', file: 'MaterialIcons-Regular.otf'),
      ]) {
        final loader = FontLoader(font.family)
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File('$fonts/${font.file}').readAsBytes(),
              ),
            ),
          );
        await loader.load();
      }
    });
    final bytes = (await tester.runAsync(_sampleDocument))!;
    final capture = GlobalKey();
    const corners = [
      Offset.zero,
      Offset(999, 0),
      Offset(999, 1399),
      Offset(0, 1399),
    ];

    Future<void> show(
      Widget screen, {
      Brightness mode = Brightness.light,
    }) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: 'Roboto',
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.deepPurple,
                brightness: mode,
              ),
            ),
            home: screen,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Let asynchronous image decoding finish before capturing the frame.
      for (final element in find.byType(Image).evaluate()) {
        final image = element.widget as Image;
        await tester.runAsync(() => precacheImage(image.image, element));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> save(String name) async {
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File('docs/screenshots/$name.png').writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        } finally {
          image.dispose();
        }
      });
    }

    ScannerHomePage home(int count) => ScannerHomePage(
      key: UniqueKey(),
      searchablePdfEnabled: true,
      initialPages: [
        for (var i = 0; i < count; i++)
          ScannedPage(
            originalBytes: bytes,
            processedBytes: bytes,
            corners: corners,
          ),
      ],
    );

    await show(home(0));
    await save('ui-home-empty');
    await show(home(3));
    expect(find.text('Export 3 pages as PDF'), findsOneWidget);
    await save('ui-home-pages');
    await tester.tap(find.byTooltip('Reorder page 2'));
    await tester.pumpAndSettle();
    await save('ui-reorder-pages');
    Navigator.of(tester.element(find.text('Move earlier'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    await save('ui-export-options');
    await tester.pumpWidget(const SizedBox());
    await show(home(3), mode: Brightness.dark);
    await save('ui-home-pages-dark');
    await tester.pumpWidget(const SizedBox());
    await show(
      CornerAdjustScreen(
        originalBytes: bytes,
        source: PageReviewSource.camera,
        operations: _PreviewFixture(bytes),
      ),
    );
    expect(
      find.text('No page edges detected. Full image selected.'),
      findsOneWidget,
    );
    await save('crop-full-image-fallback');
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    for (final element in find.byType(Image).evaluate()) {
      await tester.runAsync(
        () => precacheImage((element.widget as Image).image, element),
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('Add page'), findsOneWidget);
    expect(find.byTooltip('Adjust'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    await save('ui-adjust-appearance');
    expect(find.text('Adjust crop'), findsNothing);
    expect(find.byKey(const ValueKey('filter_original')), findsNothing);
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    for (final element in find.byType(Image).evaluate()) {
      await tester.runAsync(
        () => precacheImage((element.widget as Image).image, element),
      );
    }
    await tester.pumpAndSettle();
    await save('ui-filters-panel');
    await tester.pumpWidget(const SizedBox());
    await show(home(maxDocumentPages));
    await save('ui-intake-page-limit');
    await tester.tap(find.text('Image intake help'));
    await tester.pumpAndSettle();
    await save('ui-intake-limit-guidance');
    await tester.pumpWidget(const SizedBox());
    await show(ScannerHomePage(draftStore: _UnreadableDraftStore()));
    await save('ui-draft-restore-failure');
    await tester.tap(find.text('Discard saved draft'));
    await tester.pumpAndSettle();
    await save('ui-draft-discard-confirmation');
    debugDisableShadows = previousShadows;
  });
}
