# Native attribution review: outstanding barcode notices

## Disposition

**Keep #209 and publication acceptance open.** The source/binary scanner result
is not sufficient evidence of complete attribution. Inspection of the successful
local CI-image APK found a concrete gap in bundled barcode-library notices.
No non-free dependency is established by this finding.

## Inputs inspected

- APK SHA-256: `5072b0e922325f22b9a059b4b84ef8470ad4e2f3962a1bbd5a4ec1ece8440db2`.
- `flutter_zxing` 3.1.1, locked pub archive SHA-256:
  `aba36b8235a3a985da7dc9e300be05b62ed0a8b1b27f04cbc299ef3246e70bc6`.
- Package CMake SHA-256:
  `770fc5708659d36773ff0d6090c3eddda97c7a191c11a05d388f56489f51a5c7`.
- Vendored ZXing core CMake SHA-256:
  `2ac86c8e97eac0874f1f5efb380e4b750c9eec3928a42d72ebc8b3e3859992f2`.
- Vendored Zint `backend/library.c` SHA-256:
  `9966a1fe50bc7d8684597da36e15f2fe7e3413905190ef886f8c38787672544f`.

The package source is available through the locked pub.dev package archive;
paths below are relative to its root, not arbitrary upstream HEAD revisions.

## Evidence

1. `src/CMakeLists.txt` sets `ZXING_WRITERS BOTH`, adds `src/zxing/core`,
   and links ZXing into `flutter_zxing`.
2. `src/zxing/core/CMakeLists.txt` declares ZXing 3.1.1, enables the new writer
   for `BOTH`, and defaults to bundled Zint. It lists the selected Zint sources.
   For example, `core/src/libzint/library.c` includes
   `../../../zint/backend/library.c`.
3. The actual APK's `lib/arm64-v8a/libflutter_zxing.so` exports
   `ZBarcode_Create`, `ZBarcode_Delete`, `ZBarcode_Encode` and other Zint
   functions, confirming this is not just an unused source directory.
4. Zint's `backend/library.c` carries Robin Stuart's 2009–2025 copyright and
   BSD-3-Clause conditions, including reproducing the copyright, conditions
   and disclaimer in materials accompanying binary distributions.
5. The package-level `LICENSE` is the wrapper's MIT license. ZXing native
   sources have their own attribution and Apache-2.0 identifiers, e.g.
   `core/src/ReadBarcode.cpp` credits Axel Waggershauser.
6. The APK's decompressed `assets/flutter_assets/NOTICES.Z` contains the wrapper
   MIT entry but no `Robin Stuart`, `Axel Waggershauser` or `Zint` text.
   Other license/notice-named assets inspected were the OCR model/native
   notices, `META-INF/NOTICE.md`, and the AndroidX annotation license. None
   contained those attribution strings either. `lib/main.dart` registers only
   the standalone OCR notices in addition to Flutter's generated registry.

This identifies absent attribution for bundled code, not a conclusion that all
barcode notices can be satisfied by adding those three strings. Zint source
headers may credit other contributors or carry additional terms; inspect the
actual compiled source list before preparing a complete notice bundle. Its
repository-wide historical GPL discussion is not evidence that the selected
backend is GPL-only; do not conflate frontend licensing with backend licensing.

## Required remediation and verification

- Inventory the compiled ZXing/Zint source headers, including embedded
  third-party tables/code, and preserve all applicable notices. Obtain the
  corresponding license texts from the pinned sources.
- Bundle the resulting native notices and expose them in the app's existing
  licenses UI. Add regression coverage of asset loading and registration.
- Rebuild the chosen candidate, inspect the notices inside that exact APK and
  exercise the licenses UI. The existing successful APK is unchanged and
  does not acquire notices when this documentation is merged.
- Continue the separate OpenCV/KleidiCV, Flutter engine and CameraX attribution
  review. A match to a source/toolchain artifact does not settle notice
  completeness. This focused barcode inspection is not a full dependency audit.

See the [build milestone](fdroid-build-milestone.md) for source identity, native
origin/alignment checks and the remaining signed-device acceptance gates.
