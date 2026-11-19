import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/app_preferences.dart';
import 'package:fosscanner/widgets/screen_privacy_menu.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => false;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.fosscanner.app/screen_privacy');
  late ImagePickerPlatform originalPicker;
  late List<bool> applied;

  setUp(() {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    applied = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setSecureScreen');
      applied.add((call.arguments as Map)['enabled'] as bool);
      return null;
    });
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpHome(WidgetTester tester, AppPreferencesStore store) async {
    await tester.pumpWidget(
      MaterialApp(home: ScannerHomePage(preferencesStore: store)),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the menu and reports whether Block screenshots is checked.
  Future<({bool checked})> openMenuItem(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    final semantics = tester.widget<Semantics>(
      find.ancestor(
        of: find.text('Block screenshots'),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.checked != null,
        ),
      ),
    );
    return (checked: semantics.properties.checked!);
  }

  testWidgets(
    'Block screenshots toggles FLAG_SECURE and persists the choice',
    (tester) async {
      final store = MemoryAppPreferencesStore();
      await pumpHome(tester, store);
      // Off by default: nothing is sent at startup.
      expect(applied, isEmpty);

      var item = await openMenuItem(tester);
      expect(item.checked, isFalse);
      expect(find.text('About FOSScanner'), findsOneWidget);
      await tester.tap(find.text('Block screenshots'));
      await tester.pumpAndSettle();
      expect(applied, [true]);
      expect((await store.load()).blockScreenshots, isTrue);

      item = await openMenuItem(tester);
      expect(item.checked, isTrue);
      await tester.tap(find.text('Block screenshots'));
      await tester.pumpAndSettle();
      expect(applied, [true, false]);
      expect((await store.load()).blockScreenshots, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a saved choice is applied at startup',
    (tester) async {
      await pumpHome(
        tester,
        MemoryAppPreferencesStore(
          const AppPreferences(blockScreenshots: true, searchablePdf: true),
        ),
      );
      expect(applied, [true]);
      final item = await openMenuItem(tester);
      expect(item.checked, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'platforms without FLAG_SECURE neither show nor apply the setting',
    (tester) async {
      await pumpHome(
        tester,
        MemoryAppPreferencesStore(const AppPreferences(blockScreenshots: true)),
      );
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Block screenshots'), findsNothing);
      expect(find.text('About FOSScanner'), findsOneWidget);
      expect(applied, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a failing platform channel does not break the menu',
    (tester) async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      final store = MemoryAppPreferencesStore();
      await pumpHome(tester, store);
      await openMenuItem(tester);
      await tester.tap(find.text('Block screenshots'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect((await store.load()).blockScreenshots, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('the menu helper only builds the item where it is supported', () {
    expect(
      screenPrivacyMenuItems(supported: false, blockScreenshots: true),
      isEmpty,
    );
    final items = screenPrivacyMenuItems(
      supported: true,
      blockScreenshots: true,
    );
    final item = items.single as PopupMenuItem<String>;
    expect(item.value, blockScreenshotsMenuValue);
    expect((item.child! as Semantics).properties.checked, isTrue);
  });
}
