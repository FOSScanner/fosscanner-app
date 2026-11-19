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
import 'package:fosscanner/screens/page_preview_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/image_metadata.dart';

import 'support/home_menu.dart';
import 'support/worker_isolates.dart';
import 'support/export_bar.dart';

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

class _ObservedSharePlatform implements SharePlatform {
  final shared = Completer<ShareParams>();

  @override
  Future<ShareResult> share(ShareParams params) async {
    shared.complete(params);
    return const ShareResult('', ShareResultStatus.dismissed);
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

Uint8List _imageWithRetainedStorage(Uint8List image, int retainedBytes) {
  final storage = Uint8List(retainedBytes)..setRange(0, image.length, image);
  return Uint8List.sublistView(storage, 0, image.length);
}

void main() {
  late ImagePickerPlatform originalPlatform;

  setUp(() {
    originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _FakeImagePickerPlatform();
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPlatform;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows the empty state and capture button on launch', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FOSScannerApp());
    await tester.pumpAndSettle();

    expect(find.text('FOSScanner'), findsOneWidget);
    expect(find.text('Ready to scan'), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt_outlined), findsWidgets);

    // No captured pages yet, so there's nothing to clear or export.
    expect(await isClearAllPagesEnabled(tester), isFalse);
    expect(find.byKey(const Key('pdf_export_bar')), findsNothing);
  });

  testWidgets(
    'does not offer camera capture when the platform has no camera picker',
    (tester) async {
      ImagePickerPlatform.instance = _FakeImagePickerPlatform(
        cameraSupported: false,
      );

      await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Scan a page'), findsNothing);
      expect(
        find.text('Import from your gallery to add your first page.'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Import from gallery'),
        findsOneWidget,
      );
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
    final retainedBytes = _imageWithRetainedStorage(
      File('assets/icon/icon.png').readAsBytesSync(),
      85 * 3 * 1024 * 1024,
    );
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
      await tester.tap(find.byTooltip('Scan a page'));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect(find.textContaining('No camera is available'), findsOneWidget);
      expect(find.text('Import images'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Scan a page'), findsNothing);
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
    await tester.tap(find.byTooltip('Scan a page'));
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
            find.widgetWithIcon(
              FloatingActionButton,
              Icons.camera_alt_outlined,
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'page-limit guidance is accessible and deletion restores intake',
    (tester) async {
      final icon = File('assets/icon/icon.png').readAsBytesSync();
      final page = ScannedPage(
        originalBytes: icon,
        corners: const [],
        processedBytes: icon,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScannerHomePage(
            initialPages: List.filled(maxDocumentPages, page),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The camera button looks and reads as unavailable (#151).
      final semantics = tester.ensureSemantics();
      FloatingActionButton camera() => tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(camera().onPressed, isNull);
      expect(camera().backgroundColor, isNotNull);
      expect(camera().elevation, 0);
      expect(
        tester.getSemantics(find.byType(FloatingActionButton)),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          tooltip: 'Scan a page',
        ),
      );
      semantics.dispose();
      await tester.tap(find.byTooltip('Image intake help'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('$maxDocumentPages-page limit'),
        findsOneWidget,
      );
      expect(find.textContaining('not enough document memory'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Delete page 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete page 1'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Image intake help'), findsNothing);
      expect(camera().onPressed, isNotNull);
      expect(camera().backgroundColor, isNull);
      expect(camera().elevation, isNull);
    },
  );

  testWidgets('byte-limit guidance includes Undo and expiry restores intake', (
    tester,
  ) async {
    final icon = File('assets/icon/icon.png').readAsBytesSync();
    final retained = _imageWithRetainedStorage(icon, maxRetainedDocumentBytes);
    final page = ScannedPage(
      originalBytes: retained,
      corners: const [],
      processedBytes: retained,
    );
    await tester.pumpWidget(
      MaterialApp(home: ScannerHomePage(initialPages: [page])),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Image intake help'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not enough document memory'), findsOneWidget);
    expect(find.textContaining('pending draft save'), findsOneWidget);
    expect(find.textContaining('page limit'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Delete page 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete page 1'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Image intake help'), findsNothing);
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('unsupported camera status directs users to available gallery', (
    tester,
  ) async {
    ImagePickerPlatform.instance = _FakeImagePickerPlatform(
      cameraSupported: false,
    );
    await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Image intake help'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Use Import from gallery'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
          )
          .onPressed,
      isNotNull,
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
    final retainedBytes = _imageWithRetainedStorage(icon, 85 * 3 * 1024 * 1024);
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
    expect(find.textContaining('not enough document memory'), findsOneWidget);
  });

  testWidgets('oversized files suggest smaller files, not document capacity', (
    tester,
  ) async {
    ImagePickerPlatform.instance = _FakeImagePickerPlatform(
      images: [
        _SizedXFile('oversized.png', Uint8List(maxEncodedImageBytes + 1)),
      ],
    );
    await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pumpAndSettle();
    expect(find.textContaining('image is too large'), findsOneWidget);
    expect(find.textContaining('Choose a file under'), findsOneWidget);
    expect(find.textContaining('not enough document memory'), findsNothing);
  });

  testWidgets('a document near its limit still reviews a new image', (
    tester,
  ) async {
    final icon = File('assets/icon/icon.png').readAsBytesSync();
    // 250 MiB of the 256 MiB document limit: processing headroom no longer
    // shrinks as the document grows, so the image is reviewed.
    final retainedBytes = _imageWithRetainedStorage(icon, 50 * 5 * 1024 * 1024);
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
    // The editor keeps animating while it previews; never settle here.
    for (
      var i = 0;
      i < 20 && find.byType(CornerAdjustScreen).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(CornerAdjustScreen), findsOneWidget);
    expect(find.textContaining('Not enough memory'), findsNothing);
    expect(find.textContaining('not enough document memory'), findsNothing);
  });

  testWidgets('page taps preview the saved result and retain edits', (
    tester,
  ) async {
    final original = File('assets/icon/icon.png').readAsBytesSync();
    final processed = Uint8List.fromList(original);
    final updated = Uint8List.fromList(original);
    final page = ScannedPage(
      originalBytes: original,
      processedBytes: processed,
      corners: const [],
      filter: PageFilter.grayscale,
      rotationQuarterTurns: 1,
      brightness: 12,
      contrast: 1.3,
    );
    var metadataReads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: [page],
          cornerAdjustOperations: const _ImmediateCornerOperations(),
          sourceImageSizeReader: (_) async {
            metadataReads++;
            return const Size(1024, 1024);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Card).first);
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(PagePreviewScreen),
        matching: find.byType(Image),
      ),
    );
    final provider = image.image as ResizeImage;
    expect(
      identical((provider.imageProvider as MemoryImage).bytes, processed),
      isTrue,
    );
    expect(provider.width, 2048);
    expect(provider.height, 2048);
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(image.fit, BoxFit.contain);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(metadataReads, 0);
    expect(find.byType(CornerAdjustScreen), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(metadataReads, 0);
    await tester.tap(find.byType(Card).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit page'));
    await tester.pumpAndSettle();
    final editor = tester.widget<CornerAdjustScreen>(
      find.byType(CornerAdjustScreen),
    );
    expect(metadataReads, 1);
    expect(identical(editor.originalBytes, original), isTrue);
    expect(editor.initialFilter, PageFilter.grayscale);
    expect(editor.initialRotationQuarterTurns, 1);
    expect(editor.initialBrightness, 12);
    expect(editor.initialContrast, 1.3);
    Navigator.of(tester.element(find.byType(CornerAdjustScreen))).pop(
      ScannedPage(
        originalBytes: original,
        processedBytes: updated,
        corners: const [],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Card).first);
    await tester.pumpAndSettle();
    expect(
      identical(
        tester
            .widget<PagePreviewScreen>(find.byType(PagePreviewScreen))
            .imageBytes,
        updated,
      ),
      isTrue,
    );
  });

  testWidgets(
    'a 20MP page of a document over the cap can preview but cannot edit',
    (tester) async {
      final icon = File('assets/icon/icon.png').readAsBytesSync();
      final sharedRetainedBytes = _imageWithRetainedStorage(
        icon,
        // Initial pages bypass admission; 272 MiB leaves less than a 20 MP
        // edit needs even beyond the document limit.
        272 * 1024 * 1024,
      );
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

      expect(find.byType(PagePreviewScreen), findsOneWidget);
      expect(inspectedBytes, isNull);
      await tester.tap(find.byTooltip('Edit page'));
      await tester.pumpAndSettle();
      expect(identical(inspectedBytes, sharedRetainedBytes), isTrue);
      expect(
        find.text(
          'This page can\'t be edited while the document is this large. '
          'Remove some pages and try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('choose a smaller image'), findsNothing);
      expect(find.byType(CornerAdjustScreen), findsNothing);
    },
  );

  testWidgets(
    'rapid page taps open one preview and edit opens one editor route',
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
      expect(metadataReads, 0);
      await tester.pumpAndSettle();
      expect(observer.pushCount, 2);
      expect(find.byType(PagePreviewScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Edit page'));
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

      expect(observer.pushCount, 3);
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
    final sharedBytes = _imageWithRetainedStorage(icon, targetRetainedBytes);
    final retainedPage = ScannedPage(
      originalBytes: sharedBytes,
      corners: const [],
      processedBytes: sharedBytes,
    );
    final pages = List.filled(pageCount, retainedPage);
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

    expect(find.textContaining('not enough document memory'), findsOneWidget);
  });

  testWidgets('backend stream errors are not reported as capacity failures', (
    tester,
  ) async {
    final icon = File('assets/icon/icon.png').readAsBytesSync();
    final retainedBytes = _imageWithRetainedStorage(icon, 85 * 3 * 1024 * 1024);
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

    expect(find.text('Could not read this image.'), findsOneWidget);
    expect(find.textContaining('not enough document memory'), findsNothing);
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
          searchablePdfEnabled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findShareButton(1));
    await pumpUntil(tester, () => sharePlatform.lastParams != null);

    final params = sharePlatform.lastParams;
    expect(params, isNotNull);
    expect(params!.fileNameOverrides, hasLength(1));
    expect(
      params.fileNameOverrides!.single,
      matches(RegExp(r'^Scan \d{4}-\d{2}-\d{2} \d{2}-\d{2}\.pdf$')),
    );
  });

  testWidgets(
    'OCR is off by default and image-only export bypasses recognition',
    (tester) async {
      const channel = MethodChannel('com.fosscanner.app/ocr');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var ocrCalls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        ocrCalls++;
        throw PlatformException(code: 'unexpected_ocr');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final sharePlatform = _FakeSharePlatform();
      final imageBytes = File('assets/icon/icon.png').readAsBytesSync();
      await tester.pumpWidget(
        MaterialApp(
          home: ScannerHomePage(
            initialPages: [
              ScannedPage(
                originalBytes: imageBytes,
                processedBytes: imageBytes,
                corners: const [],
              ),
            ],
            searchablePdfEnabled: true,
            sharePlus: SharePlus.custom(sharePlatform),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('PDF export options'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(
        find.textContaining('Search and copy text in the PDF.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(findShareButton(1));
      await tester.pump();
      expect(find.byTooltip('PDF export options'), findsNothing);
      await pumpUntil(tester, () => sharePlatform.lastParams != null);
      expect(ocrCalls, 0);
      expect(find.text('Searchable export failed'), findsNothing);
      expect(
        sharePlatform.lastParams!.fileNameOverrides!.single,
        matches(RegExp(r'^Scan \d{4}-\d{2}-\d{2} \d{2}-\d{2}\.pdf$')),
      );
      expect(find.text('Keep this draft?'), findsNothing);
      expect(findShareButton(1), findsOneWidget);
      await tester.tap(find.byTooltip('PDF export options'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
    },
  );

  testWidgets(
    'keeps the share anchor while document mutations are blocked during export',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      ImagePickerPlatform.instance = _FakeImagePickerPlatform();
      const channel = MethodChannel('com.fosscanner.app/ocr');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('share_anchor_test_'),
      ))!;
      final (started, finish, sharePlatform) = (await tester.runAsync(
        () async =>
            (Completer<void>(), Completer<void>(), _ObservedSharePlatform()),
      ))!;
      messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ensureTessdata') return null;
        started.complete();
        await finish.future;
        final output = File('${(call.arguments as Map)['outputPath']}.pdf');
        await output.writeAsString('%PDF-1.5\nfixture\n%%EOF');
        return output.path;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(paths, null);
        await temporary.delete(recursive: true);
      });

      final imageBytes = File('assets/icon/icon.png').readAsBytesSync();
      await tester.pumpWidget(
        MaterialApp(
          home: ScannerHomePage(
            initialPages: [
              ScannedPage(
                originalBytes: imageBytes,
                corners: const [],
                processedBytes: imageBytes,
              ),
            ],
            sharePlus: SharePlus.custom(sharePlatform),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final staleDelete = tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Delete page 1'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed!;
      await tester.tap(find.byTooltip('PDF export options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Searchable text'));
      await tester.pumpAndSettle();
      final staleOcrChange = tester
          .widget<SwitchListTile>(find.byType(SwitchListTile))
          .onChanged!;
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final expectedAnchor = tester.getRect(find.byType(FilledButton));
      await tester.tap(findShareButton(1, searchable: true));
      await pumpUntil(tester, () => started.isCompleted, settle: false);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.byTooltip('PDF export options'), findsNothing);
      staleOcrChange(false);
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Delete page 1'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      staleDelete();
      await tester.pump();
      expect(find.text('Recognizing text…'), findsOneWidget);

      finish.complete();
      await pumpUntil(tester, () => sharePlatform.shared.isCompleted);
      final params = await tester.runAsync(() => sharePlatform.shared.future);
      debugDefaultTargetPlatformOverride = null;
      expect(params, isNotNull);
      expect(params!.sharePositionOrigin, expectedAnchor);
      expect(
        params.fileNameOverrides!.single,
        matches(
          RegExp(r'^Scan \d{4}-\d{2}-\d{2} \d{2}-\d{2} \(searchable\)\.pdf$'),
        ),
      );
      expect(params.text, isNull);
      await tester.tap(find.byTooltip('PDF export options'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
    },
  );

  testWidgets('offers an image-only fallback when searchable export fails', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final sharePlatform = _FakeSharePlatform();
    final imageBytes = File('assets/icon/icon.png').readAsBytesSync();
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
          searchablePdfEnabled: true,
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(findShareButton(1, searchable: true));
    await pumpUntilFound(
      tester,
      find.text('Searchable export failed'),
      settle: false,
    );
    expect(find.text('Searchable export failed'), findsOneWidget);
    expect(find.text('Export image-only PDF'), findsOneWidget);
    // The OCR job has ended; the fallback cannot cancel a native OCR job.
    // Cancel keeps its slot (so the status never changes width) but is off.
    expect(
      tester
          .widget<TextButton>(
            find.descendant(
              of: find.byKey(const Key('pdf_export_bar'), skipOffstage: false),
              matching: find.byType(TextButton, skipOffstage: false),
            ),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Export image-only PDF'));
    await pumpUntil(tester, () => sharePlatform.lastParams != null);
    debugDefaultTargetPlatformOverride = null;

    expect(sharePlatform.lastParams, isNotNull);
    expect(
      sharePlatform.lastParams!.fileNameOverrides!.single,
      matches(RegExp(r'^Scan \d{4}-\d{2}-\d{2} \d{2}-\d{2}\.pdf$')),
    );
  });
}
