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

**Quirk:** since `applicationId` (`com.fosscanner.app`) and the `--project-name`/org combo `flutter create .` infers from it don't share a last path segment, this regen step also drops a stray, unused `android/app/src/main/kotlin/com/fosscanner/fosscanner/MainActivity.kt` (package `com.fosscanner.fosscanner`) alongside the real one every time the container runs. Harmless — `AndroidManifest.xml`'s `.MainActivity` resolves against `namespace`, so the real `com.fosscanner.app.MainActivity` is what actually gets used — but it's untracked clutter, root-owned (needs `docker compose run --rm --entrypoint bash build-apk -c "rm -rf ..."` to remove, not a plain host `rm`), and safe to delete or ignore.

**Gotcha:** each `docker compose run` starts a fresh container with an empty `/root/.pub-cache` (only `/app` is bind-mounted) — always chain `flutter pub get &&` in front of any one-off command run this way, or every package import will fail with "No such file or directory".

## Architecture

- `lib/main.dart` — app entry + `FOSScannerApp` (Material 3 theme, follows system light/dark via `ThemeMode.system`).
- `lib/models/scanned_page.dart` — `ScannedPage` (original photo bytes, detected/adjusted corners, chosen `PageFilter`, processed bytes) and the `PageFilter` enum.
- `lib/services/document_processor.dart` — public API (`detectCorners`, `warpDocument`, `applyFilter`), all bytes-in/bytes-out. Conditionally exports:
  - `document_processor_native.dart` — the real implementation, via `opencv_dart` (Canny → contours → `approxPolyDP` epsilon-sweep → `getPerspectiveTransform`/`warpPerspective`; filters: grayscale via `cvtColor`, black-and-white via grayscale + `adaptiveThreshold`, auto-enhance via CLAHE on the L channel in Lab space). All `cv.Mat`s (and `CLAHE` instances) are explicitly `.dispose()`d.
  - `document_processor_web.dart` — no-op stub (`opencv_dart` is FFI-based and has no web support); passes the photo through unchanged regardless of filter.
  - Selected via `export '...native.dart' if (dart.library.js_interop) '...web.dart';` — same conditional-import pattern used elsewhere in the Flutter ecosystem for web-incompatible natives (see `share_plus`'s own source for another example).
- `lib/services/corner_geometry.dart` — pure-Dart geometry (`orderCorners`, `cornerDistance`), deliberately dependency-free so it's cheap to unit test and safe to use from the web stub.
- `lib/widgets/corner_overlay.dart` — `CornerOverlay`, a draggable 4-corner quad overlay on top of the captured photo. Handles all display-space ↔ image-pixel-space mapping internally; callers only ever deal in image-pixel coordinates. Owns live drag state internally (`_liveCorners`) and only calls `onChanged` once, when a drag *ends* — dragging used to call `onChanged` on every pointer move, which made the parent screen `setState` (and rebuild the full-size image, filter previews, buttons — everything) 60+ times a second, visibly stuttering. Don't reintroduce a per-frame callback here without a very good reason.
- `lib/screens/corner_adjust_screen.dart` — post-capture review, two steps (`_Step`):
  1. **Corners**: runs `detectCorners` (falling back to corners at the image bounds if nothing's found), shows `CornerOverlay` on the raw photo. "Next" advances to step 2 (awaiting preview generation if it hasn't finished yet).
  2. **Filter**: a full-size `Image.memory` of the *actual* warped+filtered result (not just a small chip) plus the filter chip row (Original/Enhance/Gray/B&W) — tapping a chip swaps which cached preview is shown full-size, so the user sees exactly what they're about to save. "Confirm" pops a `ScannedPage`; "Back" returns to step 1 without losing anything.

  Previews (a warp + all 4 filters) are regenerated in `CornerOverlay`'s `onChanged` (i.e. once per drag, not per frame — see above), cached in `_filterPreviews`, and reused at confirm time rather than recomputed if corners haven't changed since. Doubles as the re-edit screen: passing `initialCorners`/`initialFilter` (an existing page's saved values) skips detection and switches step 1's title/button wording ("Edit page"/"Cancel" vs. "Adjust corners"/"Retake") via `_isEditingExistingPage`.
- `lib/screens/scanner_home_page.dart` — the main screen, holding `List<ScannedPage>`:
  - `_captureImage()` — camera capture via `image_picker`, deletes the underlying temp file immediately after reading its bytes, then (native only) pushes `CornerAdjustScreen` and appends the result. On web, skips straight to appending the raw photo (no detect/adjust flow — see below).
  - `_editPage(index)` — tapping a thumbnail (the `InkWell` wrapping the `Card`, distinct from the delete `IconButton` inside it) re-opens `CornerAdjustScreen` pre-populated with that page's `originalBytes`/`corners`/`filter`, and replaces the entry in `_pages` on confirm. No-op on web (nothing to edit there).
  - `_removePage(index)` / `_clearPages()` — no per-page temp files to clean up anymore; everything lives in memory as `ScannedPage.processedBytes`.
  - `_generateAndSharePdf()` — builds a `pdf` `Document` from each page's `processedBytes`, shares via `SharePlus.instance.share(ShareParams(files: [XFile.fromData(...)], downloadFallbackEnabled: true))`. No temp file for the PDF either. Each PDF page is sized to match its own image's aspect ratio (`image.width/height` from `pw.MemoryImage`, at an assumed `_scanDpi` of 150) with `margin: pw.EdgeInsets.zero` — **do not** go back to a fixed `PdfPageFormat.a4` here: `.a4` has a hard-coded `marginAll: 2.0 * cm` baked into the format itself (see `package:pdf`'s `page_format.dart`), and centering a non-A4-proportioned image inside it with `BoxFit.contain` letterboxes it. Both together were the cause of a real "extra white border around my selected document" bug report — the crop itself was correct, the PDF page around it wasn't.

Key dependencies (see `pubspec.yaml`): `image_picker`, `pdf`, `share_plus` (modern `SharePlus.instance.share()` API, not the deprecated `Share.shareXFiles`), `opencv_dart` (native platforms only).

### Web has no scanning

`opencv_dart` doesn't support web. On `kIsWeb`, `ScannerHomePage` skips the detect/adjust flow entirely and treats the raw captured photo as the "processed" page (old pre-scanning behavior). Web is a preview/testing target only (see the Docker section above) — native builds are the real target for this feature. If you're debugging why detection "isn't working", check the platform first.

### Privacy behavior

Captured photos and the generated PDF are never persisted by the app: the `image_picker` temp file is deleted the moment its bytes are read, and both the warped/filtered page and the final PDF only ever exist as in-memory bytes — nothing else is written to disk by the app itself.

### Known tradeoff: APK size

Adding `opencv_dart` grew the release APK from ~49.5MB to ~83.2MB (bundled native OpenCV libs across ABIs). Two mitigations: OpenCV is already trimmed to only the modules actually used (`imgcodecs`+`imgproc`; all others compiled `OFF`, verified via the `dartcv4` CMake config in the build log). The `build-apk` Docker service also passes `--split-per-abi`, which produces one APK per ABI instead of a universal one — `app-arm64-v8a-release.apk` (the one real phones need) comes out at ~27.6MB, `armeabi-v7a` ~21.2MB, `x86_64` ~32.2MB, vs. 83.2MB universal. A plain `flutter build apk` (no flag) still produces the old universal APK; use the Docker `build-apk` service, or add `--split-per-abi` manually, to get the smaller per-ABI ones.

### Release signing & distribution

`applicationId`/`namespace` is `com.fosscanner.app` (`android/app/build.gradle.kts`); the Kotlin source lives at `android/app/src/main/kotlin/com/fosscanner/app/MainActivity.kt` to match. `ios/`, `macos/`, and `linux/` still carry the old `com.example.fosscanner` placeholder — left alone deliberately, since none of them are built by this project's CI or Docker setup (Android + web are the only real targets; see above).

Release builds are signed with a real upload key, not the debug keystore: `android/app/build.gradle.kts` reads `android/key.properties` (gitignored; copy `android/key.properties.example` and fill it in) if present, and only falls back to debug signing when that file is absent — so `flutter run --release` and the `ci.yml` analyze/test job still work with no secrets available. The GitHub Actions `release.yml` workflow reconstitutes the keystore at build time from repo secrets rather than committing it:

- `ANDROID_KEYSTORE_BASE64` — the `.jks` file, base64-encoded (`base64 -w0 android/app/upload-keystore.jks`)
- `ANDROID_KEYSTORE_PASSWORD` — used for both `storePassword` and `keyPassword`, since PKCS12 keystores (keytool's default since JDK 8u...) don't support separate ones — `keytool` silently ignores a distinct `-keypass` and warns about it
- Key alias is hardcoded as `upload` in both `key.properties` and the workflow (not a secret, just a fixed convention)

**Losing `upload-keystore.jks` (or its password) means no future release can ever be recognized as an update to this app again** — back it up outside the repo (password manager, not version control) the moment it's generated.

### F-Droid readiness

The app is GPL-3.0 (F-Droid requires an OSI-approved license) and makes no network calls (see "Privacy behavior" above), which fits F-Droid's inclusion criteria well. The real blocker: F-Droid's reproducible-build servers build from source with network access disabled, and `dartcv4` (the native backend behind `opencv_dart`) fetches OpenCV's source into `_deps/opencv-src` via CMake `FetchContent` **during** the build — confirmed directly in a build log (`cmake ... -S .../dartcv4-2.2.2/src ...` followed by compiler invocations under `.../build/*/​_deps/opencv-src/modules/imgproc/src/...`). An F-Droid submission would need this solved first — e.g. vendoring/pre-fetching the OpenCV source as an F-Droid "srclib" — before writing the actual `fdroiddata` metadata recipe (which lives in F-Droid's own repo, not this one, and isn't written yet).

### Testing gotcha: `ui.instantiateImageCodec` hangs under `flutter test`

Real image decoding via `dart:ui`'s `instantiateImageCodec` (used in `CornerAdjustScreen` to get a photo's pixel dimensions) reliably hangs forever under `flutter_test`'s fake-time test binding — confirmed via bisection that the decode itself succeeds (even wrapped in `tester.runAsync()`), but something in the test harness's teardown afterward never returns (`dart:isolate _RawReceivePort._handleMessage` in the timeout stack). This is a test-environment artifact, not a real app bug — the Phase 0 spike script (a plain `dart run`, no `flutter_test` involved) and the real APK both work fine. Don't write widget tests that wait for `CornerAdjustScreen`'s async `_initialize()` to resolve; test the synchronous pre-decode state instead, and rely on the spike script / on-device testing for full pipeline coverage.

### CRITICAL: never dispose individual elements of a `findContours` result

`cv.findContours()` returns `(VecVecPoint contours, ...)`. Disposing the *elements* of `contours` one-by-one (`for (final c in contours) c.dispose();`) is a **native double-free** — each contour is a view into the parent container's buffer, not an independent allocation. Dispose the container itself instead: `contours.dispose();`.

This was the actual root cause of a real "the app just closes when I take a photo" bug report. It's a *heap corruption* bug, not an immediate crash at the bad `dispose()` call — confirmed via bisection (`dart run`) that it only crashes later, in an unrelated later `free()` call (`SEGV_MAPERR` in `__libc_free`), and only reproduces reliably on non-trivial images (a small/simple synthetic test photo didn't trigger it; a realistic multi-megapixel photo did every time). If you ever see a segfault whose stack trace bottoms out in `__libc_free` with no relevant Dart frames, suspect a disposal-ownership bug like this one before anything else — the crash site is rarely the bug site.

Side note: an early theory for this bug was "detection blocks the UI thread long enough to trip Android's ANR watchdog," and the fix attempted was routing `detectCorners`/`warpDocument`/`applyFilter` through `compute()`/`Isolate.run()`. That was reverted — **not** because isolates are known-incompatible with `opencv_dart` in general, but because the *still-buggy* double-free code crashed even more reliably inside `Isolate.run()` in testing, which was a red herring pointing at isolates rather than at the real bug above. Isolate-offloading hasn't been re-validated against the fixed code and isn't currently used; if UI responsiveness during detection/warping ever needs revisiting, re-test isolate offloading fresh (with the fix in place) rather than assuming it's unsafe.
