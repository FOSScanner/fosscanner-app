import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:fosscanner/main.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/image_metadata.dart';

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  _FakeImagePickerPlatform({
    this.cameraSupported = true,
    LostDataResponse? lostData,
    this.image,
    this.images = const [],
  }) : lostData = lostData ?? LostDataResponse.empty();

  final bool cameraSupported;
  final LostDataResponse lostData;
  final XFile? image;
  final List<XFile> images;
  var lostDataCalls = 0;
  var imageCalls = 0;
  ImagePickerOptions? lastOptions;
  MultiImagePickerOptions? lastMultiOptions;

  @override
  bool supportsImageSource(ImageSource source) =>
      source != ImageSource.camera || cameraSupported;

  @override
  Future<LostDataResponse> getLostData() async {
    lostDataCalls++;
    return lostData;
  }

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    imageCalls++;
    lastOptions = options;
    return image;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    lastMultiOptions = options;
    return images;
  }
}

class _CameraUnavailablePlatform extends ImagePickerPlatform {
  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) {
    throw PlatformException(code: 'no_available_camera');
  }
}

class _FakeSharePlatform implements SharePlatform {
  ShareParams? lastParams;

  @override
  Future<ShareResult> share(ShareParams params) async {
    lastParams = params;
    return ShareResult.unavailable;
  }
}

class _ImmediateCornerOperations implements CornerAdjustOperations {
  const _ImmediateCornerOperations();

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(1024, 1024);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => null;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async => {for (final filter in PageFilter.values) filter: imageBytes};

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => imageBytes;

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => imageBytes;
}

class _TrackingXFile extends XFile {
  _TrackingXFile(super.path);

  var lengthCalls = 0;
  var openReadCalls = 0;

  @override
  Future<int> length() {
    lengthCalls++;
    return super.length();
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    openReadCalls++;
    return super.openRead(start, end);
  }
}

class _SizedXFile extends XFile {
  _SizedXFile(super.path, this.bytes);

  final Uint8List bytes;
  var lengthCalls = 0;

  @override
  Future<int> length() async {
    lengthCalls++;
    return bytes.length;
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) => Stream.value(
    Uint8List.sublistView(bytes, start ?? 0, end ?? bytes.length),
  );
}

class _UnsupportedStreamXFile extends _SizedXFile {
  _UnsupportedStreamXFile(super.path, super.bytes);

  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      Stream.error(UnsupportedError('backend cannot stream'));
}

class _TrackingNavigatorObserver extends NavigatorObserver {
  var pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
    super.didPush(route, previousRoute);
  }
}

class _ThrowingXFile extends XFile {
  _ThrowingXFile(super.path);

  var readCalls = 0;

  @override
  Future<int> length() {
    readCalls++;
    return Future.error(Exception('read failed'));
  }

  @override
  Future<Uint8List> readAsBytes() {
    readCalls++;
    return Future.error(Exception('read failed'));
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    readCalls++;
    return Stream.error(Exception('read failed'));
  }
}

void main() {
  late ImagePickerPlatform originalPlatform;

  setUp(() {
    originalPlatform = ImagePickerPlatform.instance;
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPlatform;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows the empty state and capture button on launch', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FOSScannerApp());

    expect(find.text('FOSScanner'), findsOneWidget);
    expect(find.text('Ready to Scan'), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt), findsWidgets);

    // No captured pages yet, so there's nothing to clear or export.
    expect(find.byIcon(Icons.clear_all), findsNothing);
    expect(find.text('Save as PDF'), findsNothing);
  });

  testWidgets(
    'does not offer camera capture when the platform has no camera picker',
    (tester) async {
      ImagePickerPlatform.instance = _FakeImagePickerPlatform(
        cameraSupported: false,
      );

      await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));

      expect(find.byTooltip('Capture Image'), findsNothing);
      expect(find.textContaining('Import from your gallery'), findsOneWidget);
    },
  );

  testWidgets('reports an Android image-picker recovery failure at startup', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final platform = _FakeImagePickerPlatform(
      lostData: LostDataResponse(
        exception: PlatformException(code: 'lost-data-error'),
      ),
    );
    ImagePickerPlatform.instance = platform;

    await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
    await tester.pump();
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(platform.lostDataCalls, 1);
    expect(
      find.text('Could not recover the interrupted image selection.'),
      findsOneWidget,
    );
  });

  testWidgets('continues Android recovery after one unreadable image', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final directory = Directory.systemTemp.createTempSync(
      'fosscanner-recovery-',
    );
    final unreadableFile = File('${directory.path}/unreadable.jpg')
      ..writeAsBytesSync(const [1, 2, 3]);
    final validFile = File('${directory.path}/valid.png')
      ..writeAsBytesSync(File('assets/icon/icon.png').readAsBytesSync());
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final unreadable = _ThrowingXFile(unreadableFile.path);
    final valid = _TrackingXFile(validFile.path);
    final platform = _FakeImagePickerPlatform(
      lostData: LostDataResponse(files: [unreadable, valid]),
    );
    ImagePickerPlatform.instance = platform;

    await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
    for (
      var i = 0;
      i < 20 && find.byType(CornerAdjustScreen).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    debugDefaultTargetPlatformOverride = null;

    expect(platform.lostDataCalls, 1);
    expect(unreadable.readCalls, 1);
    expect(valid.lengthCalls, 1);
    expect(valid.openReadCalls, 1);
    expect(find.byType(CornerAdjustScreen), findsOneWidget);
    expect(unreadableFile.existsSync(), isFalse);
    expect(validFile.existsSync(), isFalse);
  });

  testWidgets('recovery deletes app-owned files skipped after capacity', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final directory = Directory.systemTemp.createTempSync(
      'fosscanner-recovery-capacity-',
    );
    final bytes = Uint8List(2 * 1024 * 1024);
    final firstFile = File('${directory.path}/first.jpg')
      ..writeAsBytesSync(bytes);
    final secondFile = File('${directory.path}/second.jpg')
      ..writeAsBytesSync(bytes);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final retainedBytes = Uint8List(3 * 1024 * 1024);
    final page = ScannedPage(
      originalBytes: retainedBytes,
      corners: const [],
      processedBytes: retainedBytes,
    );
    ImagePickerPlatform.instance = _FakeImagePickerPlatform(
      lostData: LostDataResponse(
        files: [
          _SizedXFile(firstFile.path, bytes),
          _SizedXFile(secondFile.path, bytes),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: ScannerHomePage(initialPages: List.filled(85, page))),
    );
    for (
      var i = 0;
      i < 20 && (firstFile.existsSync() || secondFile.existsSync());
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    debugDefaultTargetPlatformOverride = null;

    expect(firstFile.existsSync(), isFalse);
    expect(secondFile.existsSync(), isFalse);
  });

  testWidgets(
    'hides camera UI after the Android picker definitively reports no camera',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = _CameraUnavailablePlatform();
      expect(platform.supportsImageSource(ImageSource.camera), isTrue);
      ImagePickerPlatform.instance = platform;

      await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Capture Image'));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect(find.text('Could not open the camera.'), findsOneWidget);
      expect(find.byTooltip('Capture Image'), findsNothing);
      expect(find.textContaining('Import from your gallery'), findsOneWidget);
    },
  );

  testWidgets('deletes an app-owned camera file when reading it fails', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'fosscanner-camera-cleanup-',
    );
    final file = File('${directory.path}/capture.jpg')
      ..writeAsBytesSync(const [1, 2, 3]);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final image = _ThrowingXFile(file.path);
    final platform = _FakeImagePickerPlatform(image: image);
    ImagePickerPlatform.instance = platform;

    await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
    await tester.pump();
    await tester.tap(find.byTooltip('Capture Image'));
    for (var i = 0; i < 20 && file.existsSync(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 100));

    expect(platform.imageCalls, 1);
    expect(platform.lastOptions?.maxWidth, maxPickerEdge);
    expect(platform.lastOptions?.maxHeight, maxPickerEdge);
    expect(image.readCalls, 1);
    expect(image.path, file.path);
    expect(file.existsSync(), isFalse);
  });

  test('iOS declares the gallery privacy usage description', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<key>NSPhotoLibraryUsageDescription</key>'));
  });

  test('sandboxed macOS builds can read user-selected gallery files', () {
    for (final path in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('<key>com.apple.security.files.user-selected.read-only</key>'),
        reason: path,
      );
    }
  });

  test('gallery-only Android devices are allowed to install the app', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      manifest,
      contains(
        'android:name="android.hardware.camera" android:required="false"',
      ),
    );
  });

  testWidgets('disables image intake at the document page limit', (
    tester,
  ) async {
    final imageBytes = File('assets/icon/icon.png').readAsBytesSync();
    final page = ScannedPage(
      originalBytes: imageBytes,
      corners: const [],
      processedBytes: imageBytes,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: List.filled(maxDocumentPages, page),
        ),
      ),
    );

    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FloatingActionButton>(
            find.widgetWithIcon(FloatingActionButton, Icons.camera_alt),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('gallery selection is capped to the remaining page slots', (
    tester,
  ) async {
    final imageBytes = File('assets/icon/icon.png').readAsBytesSync();
    final page = ScannedPage(
      originalBytes: imageBytes,
      corners: const [],
      processedBytes: imageBytes,
    );
    final platform = _FakeImagePickerPlatform();
    ImagePickerPlatform.instance = platform;

    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: List.filled(maxDocumentPages - 2, page),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
        )
        .onPressed!();
    await tester.pumpAndSettle();

    expect(platform.lastMultiOptions?.limit, 2);
  });

  testWidgets('gallery intake stops after reaching residual byte capacity', (
    tester,
  ) async {
    final icon = File('assets/icon/icon.png').readAsBytesSync();
    final retainedBytes = Uint8List(3 * 1024 * 1024)
      ..setRange(0, icon.length, icon);
    final page = ScannedPage(
      originalBytes: retainedBytes,
      corners: const [],
      processedBytes: retainedBytes,
    );
    final selections = [
      for (var i = 0; i < 20; i++)
        _SizedXFile('selection-$i.png', Uint8List(2 * 1024 * 1024)),
    ];
    final platform = _FakeImagePickerPlatform(images: selections);
    ImagePickerPlatform.instance = platform;

    await tester.pumpWidget(
      MaterialApp(home: ScannerHomePage(initialPages: List.filled(85, page))),
    );
    await tester.pumpAndSettle();
    tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
        )
        .onPressed!();
    await tester.pumpAndSettle();

    expect(selections.fold(0, (sum, file) => sum + file.lengthCalls), 1);
    expect(
      find.textContaining('Document memory limit reached'),
      findsOneWidget,
    );
  });

  testWidgets('gallery reports a distinct transient processing-budget error', (
    tester,
  ) async {
    final icon = File('assets/icon/icon.png').readAsBytesSync();
    final retainedBytes = Uint8List(5 * 1024 * 1024)
      ..setRange(0, icon.length, icon);
    final page = ScannedPage(
      originalBytes: retainedBytes,
      corners: const [],
      processedBytes: retainedBytes,
    );
    ImagePickerPlatform.instance = _FakeImagePickerPlatform(
      images: [_SizedXFile('selection.png', icon)],
    );

    await tester.pumpWidget(
      MaterialApp(home: ScannerHomePage(initialPages: List.filled(50, page))),
    );
    await tester.pumpAndSettle();
    tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
        )
        .onPressed!();
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This image needs too much temporary memory to process safely. '
        'Remove pages or choose a smaller image.',
      ),
      findsOneWidget,
    );
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(find.textContaining('Document memory limit reached'), findsNothing);
  });

  testWidgets(
    'initial 20MP-metadata page near the cap cannot open the editor',
    (tester) async {
      final icon = File('assets/icon/icon.png').readAsBytesSync();
      final sharedRetainedBytes = Uint8List(2 * 1024 * 1024)
        ..setRange(0, icon.length, icon);
      final page = ScannedPage(
        originalBytes: sharedRetainedBytes,
        corners: const [
          Offset(0, 0),
          Offset(3999, 0),
          Offset(3999, 4999),
          Offset(0, 4999),
        ],
        processedBytes: sharedRetainedBytes,
      );
      Uint8List? inspectedBytes;

      await tester.pumpWidget(
        MaterialApp(
          home: ScannerHomePage(
            initialPages: List.filled(52, page),
            sourceImageSizeReader: (bytes) async {
              inspectedBytes = bytes;
              return const Size(4000, 5000);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Card).first);
      await tester.pumpAndSettle();

      expect(identical(inspectedBytes, sharedRetainedBytes), isTrue);
      expect(
        find.text(
          'This image needs too much temporary memory to process safely. '
          'Remove pages or choose a smaller image.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CornerAdjustScreen), findsNothing);
    },
  );

  testWidgets(
    'rapid page taps perform one metadata read and open one editor route',
    (tester) async {
      final icon = File('assets/icon/icon.png').readAsBytesSync();
      final page = ScannedPage(
        originalBytes: icon,
        corners: const [],
        processedBytes: icon,
      );
      final metadata = Completer<Size>();
      final observer = _TrackingNavigatorObserver();
      var metadataReads = 0;

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: ScannerHomePage(
            initialPages: [page],
            cornerAdjustOperations: const _ImmediateCornerOperations(),
            sourceImageSizeReader: (_) {
              metadataReads++;
              return metadata.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byType(Card).first;

      await tester.tap(card);
      await tester.tap(card);
      expect(metadataReads, 1);

      await tester.pump();
      expect(
        tester
            .widget<InkWell>(
              find.descendant(of: card, matching: find.byType(InkWell)).first,
            )
            .onTap,
        isNull,
      );

      metadata.complete(const Size(1024, 1024));
      await tester.pumpAndSettle();

      expect(observer.pushCount, 2);
      expect(find.byType(CornerAdjustScreen), findsOneWidget);
      final offstageHomeCard = find
          .descendant(
            of: find.byType(ScannerHomePage, skipOffstage: false),
            matching: find.byType(Card, skipOffstage: false),
            skipOffstage: false,
          )
          .first;
      expect(
        tester
            .widget<InkWell>(
              find
                  .descendant(
                    of: offstageHomeCard,
                    matching: find.byType(InkWell, skipOffstage: false),
                    skipOffstage: false,
                  )
                  .first,
            )
            .onTap,
        isNull,
      );

      Navigator.of(tester.element(find.byType(CornerAdjustScreen))).pop();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InkWell>(
              find
                  .descendant(
                    of: find.byType(Card).first,
                    matching: find.byType(InkWell),
                  )
                  .first,
            )
            .onTap,
        isNotNull,
      );
    },
  );

  testWidgets('gallery reports capacity when a prior selection fills it', (
    tester,
  ) async {
    final icon = File('assets/icon/icon.png').readAsBytesSync();
    const pageCount = 90;
    const additionalProcessedBytes = 24 * 1024 * 1024;
    final targetRetainedBytes =
        maxRetainedDocumentBytes - icon.length - additionalProcessedBytes;
    final sharedLength = targetRetainedBytes ~/ pageCount;
    final sharedBytes = Uint8List(sharedLength);
    final remainderBytes = Uint8List(
      targetRetainedBytes - sharedLength * (pageCount - 1),
    );
    ScannedPage pageFor(Uint8List bytes) => ScannedPage(
      originalBytes: bytes,
      corners: const [],
      processedBytes: bytes,
    );
    final pages = [
      ...List.filled(pageCount - 1, pageFor(sharedBytes)),
      pageFor(remainderBytes),
    ];
    final platform = _FakeImagePickerPlatform(
      images: [_SizedXFile('first.png', icon), _SizedXFile('second.png', icon)],
    );
    ImagePickerPlatform.instance = platform;

    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: pages,
          cornerAdjustOperations: const _ImmediateCornerOperations(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    final editor = tester.widget<CornerAdjustScreen>(
      find.byType(CornerAdjustScreen),
    );
    Navigator.of(tester.element(find.byType(CornerAdjustScreen))).pop(
      ScannedPage(
        originalBytes: editor.originalBytes,
        corners: const [],
        processedBytes: Uint8List(additionalProcessedBytes),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Document memory limit reached'),
      findsOneWidget,
    );
  });

  testWidgets('backend stream errors are not reported as capacity failures', (
    tester,
  ) async {
    final icon = File('assets/icon/icon.png').readAsBytesSync();
    final retainedBytes = Uint8List(3 * 1024 * 1024)
      ..setRange(0, icon.length, icon);
    final page = ScannedPage(
      originalBytes: retainedBytes,
      corners: const [],
      processedBytes: retainedBytes,
    );
    final platform = _FakeImagePickerPlatform(
      images: [
        _UnsupportedStreamXFile('unsupported.png', Uint8List(512 * 1024)),
      ],
    );
    ImagePickerPlatform.instance = platform;

    await tester.pumpWidget(
      MaterialApp(home: ScannerHomePage(initialPages: List.filled(85, page))),
    );
    await tester.pumpAndSettle();
    tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
        )
        .onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('Could not read this photo.'), findsOneWidget);
    expect(find.textContaining('Document memory limit reached'), findsNothing);
  });

  testWidgets('page thumbnails request a bounded decode size', (tester) async {
    final imageBytes = File('assets/icon/icon.png').readAsBytesSync();
    final page = ScannedPage(
      originalBytes: imageBytes,
      corners: const [],
      processedBytes: imageBytes,
    );

    await tester.pumpWidget(
      MaterialApp(home: ScannerHomePage(initialPages: [page])),
    );

    final image = tester.widget<Image>(
      find
          .descendant(of: find.byType(Card), matching: find.byType(Image))
          .first,
    );
    final provider = image.image as ResizeImage;
    expect(provider.width, 512);
    expect(provider.height, 512);
    expect(provider.policy, ResizeImagePolicy.fit);
  });

  testWidgets('shares PDFs with the requested attachment filename', (
    tester,
  ) async {
    final imageBytes = File('assets/icon/icon.png').readAsBytesSync();
    final sharePlatform = _FakeSharePlatform();
    final page = ScannedPage(
      originalBytes: imageBytes,
      corners: const [],
      processedBytes: imageBytes,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: [page],
          sharePlus: SharePlus.custom(sharePlatform),
        ),
      ),
    );
    await tester.tap(find.text('Save as PDF (1 pages)'));
    await tester.pumpAndSettle();

    final params = sharePlatform.lastParams;
    expect(params, isNotNull);
    expect(params!.fileNameOverrides, hasLength(1));
    expect(
      params.fileNameOverrides!.single,
      matches(RegExp(r'^FOSScanner_\d+\.pdf$')),
    );
  });
}
