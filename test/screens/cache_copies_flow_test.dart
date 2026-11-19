import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../support/home_menu.dart';
import '../support/worker_isolates.dart';
import '../support/export_bar.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];
const _uuid = '3f2a9c1e-7b4d-4e8a-9f0c-12ab34cd56ef';

class _Picker extends ImagePickerPlatform {
  List<XFile> galleryPhotos = [];

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => null;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => galleryPhotos;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

/// Copies the shared file into `share_plus/` like the Android plugin does.
class _Share implements SharePlatform {
  _Share(this.cache, this.status);

  final Directory cache;
  final ShareResultStatus status;
  File? copy;
  ShareParams? params;

  @override
  Future<ShareResult> share(ShareParams params) async {
    this.params = params;
    final source = File(params.files!.single.path);
    final folder = Directory('${cache.path}/share_plus')..createSync();
    copy = source.copySync(
      '${folder.path}/${params.fileNameOverrides!.single}',
    );
    return ShareResult('', status);
  }
}

class _Operations implements CornerAdjustOperations {
  @override
  Future<Size> decodeSize(Uint8List bytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List bytes) async => _corners;

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

void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late Directory root;
  late Directory cache;
  late Uint8List bytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    picker = _Picker();
    ImagePickerPlatform.instance = picker;
    root = Directory.systemTemp.createTempSync('cache_copies_flow_');
    cache = Directory('${root.path}/cache')..createSync();
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    root.deleteSync(recursive: true);
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    SharePlatform? share,
    List<ScannedPage> pages = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: pages,
          searchablePdfEnabled: false,
          sharePlus: share == null ? null : SharePlus.custom(share),
          cornerAdjustOperations: _Operations(),
          sourceImageSizeReader: (_) async => const Size(100, 100),
          temporaryDirectory: () async => cache,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> acceptReview(WidgetTester tester) async {
    await pumpUntilFound(tester, find.text('Preview page'));
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'gallery import deletes picker copies but never the original',
    (tester) async {
      final scaled = File('${cache.path}/scaled_IMG_1.png')
        ..writeAsBytesSync(bytes);
      final copy = File('${cache.path}/$_uuid/IMG_2.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      // The unscaled copy image_picker keeps next to a scaled one.
      final unscaled = File(
        '${cache.path}/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/IMG_1.png',
      )..createSync(recursive: true);
      final original = File('${root.path}/IMG_3.png')..writeAsBytesSync(bytes);
      picker.galleryPhotos = [
        XFile(scaled.path),
        XFile(copy.path),
        XFile(original.path),
      ];

      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      for (var i = 0; i < 3; i++) {
        await acceptReview(tester);
      }
      await settle(tester);

      expect(findShareButton(3), findsOneWidget);
      expect(scaled.existsSync(), isFalse);
      expect(copy.existsSync(), isFalse);
      expect(copy.parent.existsSync(), isFalse);
      expect(unscaled.parent.existsSync(), isFalse);
      expect(original.existsSync(), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  ScannedPage page() =>
      ScannedPage(originalBytes: bytes, processedBytes: bytes, corners: []);

  testWidgets('a dismissed share sheet removes the share copy', (tester) async {
    final share = _Share(cache, ShareResultStatus.dismissed);
    await pumpHome(tester, share: share, pages: [page()]);
    await tester.tap(findShareButton(1));
    await pumpUntil(tester, () => share.copy != null);
    await pumpUntil(tester, () => !share.copy!.existsSync());
    expect(Directory('${cache.path}/share_plus').listSync(), isEmpty);
  });

  testWidgets('after a successful share the copy stays until Clear all', (
    tester,
  ) async {
    final share = _Share(cache, ShareResultStatus.success);
    // Not ours: another file in the share folder is left alone.
    final foreign = File('${cache.path}/share_plus/notes.pdf')
      ..createSync(recursive: true);
    await pumpHome(tester, share: share, pages: [page()]);
    await tester.tap(findShareButton(1));
    await pumpUntil(tester, () => share.copy != null);
    await pumpUntilFound(tester, findShareButton(1));
    // The receiving app may still be reading it.
    expect(share.copy!.existsSync(), isTrue);

    await tapClearAllPages(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await pumpUntil(tester, () => !share.copy!.existsSync());
    expect(foreign.existsSync(), isTrue);
  });
}
