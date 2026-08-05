# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

FOSScanner is a privacy-first, FOSS (free and open source) document scanner built with Flutter. It captures photos via the device camera, lets the user manage the captured pages, and compiles them into a shareable PDF — all processed on-device (no cloud/network calls).

## Commands

This is a standard Flutter app (Dart SDK `>=3.0.0 <4.0.0`). Run these from the repo root.

- Install dependencies: `flutter pub get`
- Run the app (device/emulator/web): `flutter run`
- Static analysis / lint: `flutter analyze` (uses `analysis_options.yaml`, which includes `package:flutter_lints/flutter.yaml`)
- Run all tests: `flutter test`
- Run a single test file: `flutter test test/widget_test.dart`
- Build Android APK: `flutter build apk`
- Build web release: `flutter build web`

### Docker

`docker-compose.yml` defines two services (both build from the root `Dockerfile`, based on `ghcr.io/cirruslabs/flutter:stable`, with `cmake`/`build-essential` layered on top — required for `opencv_dart`'s native build hooks at `pub get` time):

- `flutter-web`: `flutter create . && flutter pub get && flutter build web`, then serves `build/web` with a plain `python3 -m http.server` on port 8080. Deliberately a real release build, not `flutter run -d web-server` — the debug dev-server ships an unoptimized multi-megabyte JS bundle that can fail to render on a phone's browser.
- `build-apk`: `flutter create . && flutter pub get && flutter build apk`, output at `build/app/outputs/flutter-apk/app-release.apk`.

Both mount the repo into `/app` and re-run `flutter create .` on startup to regenerate platform scaffolding before building.

**Gotcha:** each `docker compose run` starts a fresh container with an empty `/root/.pub-cache` (only `/app` is bind-mounted) — always chain `flutter pub get &&` in front of any one-off command run this way, or every package import will fail with "No such file or directory".

## Architecture

- `lib/main.dart` — app entry + `FOSScannerApp` (Material 3 theme, follows system light/dark via `ThemeMode.system`).
- `lib/models/scanned_page.dart` — `ScannedPage` (original photo bytes, detected/adjusted corners, chosen `PageFilter`, processed bytes) and the `PageFilter` enum.
- `lib/services/document_processor.dart` — public API (`detectCorners`, `warpDocument`, `applyFilter`), all bytes-in/bytes-out. Conditionally exports:
  - `document_processor_native.dart` — the real implementation, via `opencv_dart` (Canny → contours → `approxPolyDP` epsilon-sweep → `getPerspectiveTransform`/`warpPerspective`). All `cv.Mat`s are explicitly `.dispose()`d.
  - `document_processor_web.dart` — no-op stub (`opencv_dart` is FFI-based and has no web support); passes the photo through unchanged.
  - Selected via `export '...native.dart' if (dart.library.js_interop) '...web.dart';` — same conditional-import pattern used elsewhere in the Flutter ecosystem for web-incompatible natives (see `share_plus`'s own source for another example).
- `lib/services/corner_geometry.dart` — pure-Dart geometry (`orderCorners`, `cornerDistance`), deliberately dependency-free so it's cheap to unit test and safe to use from the web stub.
- `lib/widgets/corner_overlay.dart` — `CornerOverlay`, a draggable 4-corner quad overlay on top of the captured photo. Handles all display-space ↔ image-pixel-space mapping internally; callers only ever deal in image-pixel coordinates.
- `lib/screens/corner_adjust_screen.dart` — post-capture review screen: runs `detectCorners` (falling back to corners at the image bounds if nothing's found), shows `CornerOverlay`, and on confirm runs `warpDocument`/`applyFilter` and pops a `ScannedPage`.
- `lib/screens/scanner_home_page.dart` — the main screen, holding `List<ScannedPage>`:
  - `_captureImage()` — camera capture via `image_picker`, deletes the underlying temp file immediately after reading its bytes, then (native only) pushes `CornerAdjustScreen` and appends the result. On web, skips straight to appending the raw photo (no detect/adjust flow — see below).
  - `_removePage(index)` / `_clearPages()` — no per-page temp files to clean up anymore; everything lives in memory as `ScannedPage.processedBytes`.
  - `_generateAndSharePdf()` — builds a `pdf` `Document` from each page's `processedBytes`, shares via `SharePlus.instance.share(ShareParams(files: [XFile.fromData(...)], downloadFallbackEnabled: true))`. No temp file for the PDF either.

Key dependencies (see `pubspec.yaml`): `image_picker`, `pdf`, `share_plus` (modern `SharePlus.instance.share()` API, not the deprecated `Share.shareXFiles`), `opencv_dart` (native platforms only).

### Web has no scanning

`opencv_dart` doesn't support web. On `kIsWeb`, `ScannerHomePage` skips the detect/adjust flow entirely and treats the raw captured photo as the "processed" page (old pre-scanning behavior). Web is a preview/testing target only (see the Docker section above) — native builds are the real target for this feature. If you're debugging why detection "isn't working", check the platform first.

### Privacy behavior

Captured photos and the generated PDF are never persisted by the app: the `image_picker` temp file is deleted the moment its bytes are read, and both the warped/filtered page and the final PDF only ever exist as in-memory bytes — nothing else is written to disk by the app itself.

### Known tradeoff: APK size

Adding `opencv_dart` grew the release APK from ~49.5MB to ~83.2MB (bundled native OpenCV libs across ABIs). Known mitigations not yet applied: `flutter build apk --split-per-abi`, trimming to only the OpenCV modules actually used (currently `imgcodecs`+`imgproc`).

### Testing gotcha: `ui.instantiateImageCodec` hangs under `flutter test`

Real image decoding via `dart:ui`'s `instantiateImageCodec` (used in `CornerAdjustScreen` to get a photo's pixel dimensions) reliably hangs forever under `flutter_test`'s fake-time test binding — confirmed via bisection that the decode itself succeeds (even wrapped in `tester.runAsync()`), but something in the test harness's teardown afterward never returns (`dart:isolate _RawReceivePort._handleMessage` in the timeout stack). This is a test-environment artifact, not a real app bug — the Phase 0 spike script (a plain `dart run`, no `flutter_test` involved) and the real APK both work fine. Don't write widget tests that wait for `CornerAdjustScreen`'s async `_initialize()` to resolve; test the synchronous pre-decode state instead, and rely on the spike script / on-device testing for full pipeline coverage.
