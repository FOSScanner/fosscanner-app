<div align="center">

# FOSScanner

**Scan documents. Keep them on your device.**

A free and open-source document scanner for Android and iOS.
Capture or import pages, straighten and adjust them, then export a PDF.
No account, no cloud processing, no tracking.

[![License: GPL v3](https://img.shields.io/github/license/FOSScanner/fosscanner-app?color=blue)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/FOSScanner/fosscanner-app/ci.yml?branch=main&label=CI)](https://github.com/FOSScanner/fosscanner-app/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/FOSScanner/fosscanner-app?label=release)](https://github.com/FOSScanner/fosscanner-app/releases/latest)

[**Download Android APK**](https://github.com/FOSScanner/fosscanner-app/releases/latest) ·
[Report an issue](https://github.com/FOSScanner/fosscanner-app/issues) ·
[Contribute](CONTRIBUTING.md)

</div>

> **Development preview:** this README describes the current source, including
> UI changes being prepared for the next release. The latest published APK may
> look different. Check the [release notes](https://github.com/FOSScanner/fosscanner-app/releases)
> for what is available to download.

## A simple scanning workflow

1. **Add pages** with the camera button or import photos from your gallery.
2. **Check the crop.** Drag the corners to the page edges. If detection fails,
   the full image is selected rather than trimmed.
3. **Preview and adjust.** Choose **Preview page**, then tap the **Filters** icon
   to open filter choices, rotate, or adjust brightness and contrast. **Reset adjustments** restores
   neutral brightness/contrast without changing your crop, filter, or rotation.
4. **Build your document.** Choose **Add page**, then scan more pages. Tap a
   page to zoom in and choose Edit to change its appearance. Use the editor’s
   back arrow to revisit the crop; back again leaves the editor without saving.
   Save an edit with **Save changes**.
5. **Export PDF** to the system share sheet and choose where to send or save it.
   On Android, **PDF export options** lets you turn searchable text on or off.

Use each page's **Reorder page** (up/down arrows) menu to **Move earlier** or
**Move later**, or long-press and drag pages to reorder them. The page grid
adds columns on tablets and in landscape. Deleting a page
offers **Undo** for four seconds. In a multi-image gallery import, **Skip image** skips only the
current photo; remaining images are still reviewed. The review title shows
the position (for example *Image 2 of 5*), and **Stop importing** (or Back)
ends the batch while keeping pages already added. Canceling an unsaved
capture or single-image review adds no page.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/ui-home-pages.png" width="260" alt="Document overview with three page previews, temporary-draft guidance, and compact PDF export controls"><br>Review your document</td>
    <td align="center"><img src="docs/screenshots/crop-full-image-fallback.png" width="260" alt="Minimal crop editor with draggable corners and full-image fallback guidance"><br>Check the crop</td>
    <td align="center"><img src="docs/screenshots/ui-adjust-appearance.png" width="260" alt="Appearance editor showing a larger page preview, numeric adjustments, a Filters icon, and Add page"><br>Adjust the appearance</td>
  </tr>
</table>

[Empty state](docs/screenshots/ui-home-empty.png) ·
[Dark theme](docs/screenshots/ui-home-pages-dark.png) ·
[PDF export options](docs/screenshots/ui-export-options.png) ·
[Complete barcode review](docs/screenshots/barcode-complete-url.png)

*The first six images are Flutter widget renders of the current candidate using
synthetic documents. The barcode example is a separately rendered UI fixture.
They are not camera captures or demonstrations of OCR/filter quality.
[Rendering details and reproduction](docs/screenshots/README.md).*

## What it does

| Capability | Android | iOS |
|---|---|---|
| Camera capture and gallery import | Yes | Yes |
| Edge detection, manual crop, perspective correction | Yes | Yes |
| Original, Enhance, Grayscale, Black & white filters | Yes | Yes |
| Rotation, brightness, contrast, and later re-editing | Yes | Yes |
| Multi-page PDF export through the system share sheet | Yes | Yes |
| Offline searchable PDFs with selectable text | Yes — Latin-script OCR | Image-only PDFs |
| Temporary draft restoration after app restart | Yes | Yes |
| QR/barcode scanning and full-result inspection | Yes | Yes |
| System light/dark theme | Yes | Yes |

Perspective correction and filters use OpenCV. Searchable PDFs use bundled,
offline Tesseract data. On Android, searchable text is off by default; enable it
in **PDF export options**. Your choice stays in effect while the home screen
remains open. Recognition
quality depends on the document, language, lighting, and image quality.

The editor keeps the last successful preview visible while processing a new
adjustment. If it fails, retry the preview before saving. PDF generation shows
progress and offers cancellation; document editing and intake pause during
generation and sharing to avoid overlapping memory-heavy operations.

Barcode results are selectable and can be copied in full. For HTTP/HTTPS links,
you can inspect the destination hostname before choosing to open the browser.

## Install

### Android

Download an APK from the [latest release's assets](https://github.com/FOSScanner/fosscanner-app/releases/latest):

- **`app-arm64-v8a-release.apk`** — for devices that support 64-bit ARM apps;
  the usual choice for modern Android phones.
- **`app-armeabi-v7a-release.apk`** — for devices that require 32-bit ARM apps.

Your browser or file manager may ask for permission to install this APK.
Use official release assets, and keep the same signing identity when updating.
Avoid uninstalling just to resolve an update problem: uninstalling removes drafts.

### iOS

Build from source on macOS with Flutter and Xcode. Installing on an iPhone or
iPad requires the appropriate Apple signing setup; the Android APK cannot be
used on iOS. See [development](#development) below.

## Privacy and your documents

**Scanning, image processing, OCR, and PDF generation run on your device.**
FOSScanner has no login, telemetry, analytics, or scan-upload service. Imported
gallery originals are not modified or deleted. App-owned camera temporary files
are cleaned up after the attempt to read them, including failed reads.

### Drafts are temporary, not a backup

Unfinished documents are saved in the app's private, **OS-managed cache** so they
can be restored after a normal restart. The OS can purge this cache under storage
pressure. **Export a PDF and save it somewhere durable before relying on it.**

- A draft contains original and processed page images plus editing settings.
  Atomic saves can retain the current and one previous draft generation.
- Sharing keeps the draft by default. Use the **Clear all** toolbar action and
  confirm when you want to start over. Clearing app storage or uninstalling also
  removes draft data; Android OS backups do not include it.
- If restoration fails, adding images and draft saves are paused so they cannot
  silently replace the cached draft. Use **Retry restoration** after checking
  storage access. **Discard saved draft** requires confirmation and deletes both
  cached generations, including potentially recoverable pages; exported PDFs
  are not removed. A valid backup is recovered automatically when possible.
- If saving fails, a persistent warning offers **Retry saving draft**. Keep the
  app open and retry; the retry saves your current pages, not an old snapshot.
- Unrelated notifications wait while deletion Undo is available. A new deletion
  replaces the previous Undo; export or confirmed clearing discards it.

### Sharing and external links

Export opens the OS share sheet; it does not prove that another app saved or
delivered the PDF. Sharing may leave a PDF copy in an app/OS cache, whose lifetime
is platform-managed. Receiving apps control their own copies and may upload them.

FOSScanner does not make its own network requests. Opening a scanned HTTP/HTTPS
link or the source-code link hands it to an external app, which may use the
network. Only open destinations you trust.

## Development

Use **Flutter 3.44.0 / Dart 3.12**, matching CI and `.flutter-version`.

```bash
flutter pub get
flutter run

# Checks used by CI
flutter analyze
flutter test
```

### Build from source

```bash
# Signed Android APKs; configure your release keystore first
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64

# iOS build check on macOS, without device signing
flutter build ios --no-codesign
```

For Android signing, copy and configure
[`android/key.properties.example`](android/key.properties.example). Keep the
real properties file and keystore out of git; never share signing credentials.

For a containerized **debug** Android build:

```bash
# Produces ARMv7 and ARM64 debug APKs in ./docker-output/
docker compose run --rm build-apk
```

The Docker service pins a Flutter image and uses the x86_64 Android toolchain.
Apple Silicon uses Docker Desktop emulation; native ARM64 Linux needs amd64
emulation configured. Builds are limited to two CPUs and 4 GiB RAM with no extra
swap; Gradle and OpenCV parallelism are also bounded. Leave at least 4 GiB
available. These limits contain resource use but do not guarantee every build
will finish with that memory budget.

<details>
<summary>Runtime memory limits</summary>

Image admission counts encoded buffers held by pages, pending/active draft
saves, and Undo, counting shared allocations once. Deleting a page may not free
that budget immediately. Editors and PDF export share a processing queue;
export blocks document mutation until generation and sharing finish.

These are admission estimates, not a hard process-memory limit. Decoded image
caches, native OpenCV/OCR allocations, worker copies, and the finished PDF add
memory beyond the estimate. Lower-memory device profiling is still needed.

</details>

## Contributing and security

Issues and pull requests are welcome. Follow [CONTRIBUTING.md](CONTRIBUTING.md):
branch from `dev`, target PRs to `dev`, and keep changes focused. New dependencies
must be FOSS, and document processing must stay on-device.

Report vulnerabilities using [SECURITY.md](SECURITY.md), not a public issue
containing sensitive details. Version history is in [CHANGELOG.md](CHANGELOG.md).

## License

FOSScanner is licensed under the [GNU General Public License v3.0](LICENSE).
Bundled OCR data and native dependencies have their own notices; see
[`assets/tessdata/`](assets/tessdata/) and the app's license information.
