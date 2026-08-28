# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0](https://github.com/FOSScanner/fosscanner-app/compare/v1.2.2...v1.3.0) (2026-08-28)


### Features

* add in-app about screen with version and source link ([c3e4c56](https://github.com/FOSScanner/fosscanner-app/commit/c3e4c56cc940cab7e39e5c2e2e61b7bb8caf85c1))
* add QR/barcode scanning as a standalone camera mode ([18dc243](https://github.com/FOSScanner/fosscanner-app/commit/18dc243bbe22f8fbd803a7d0e5558090b03e9cb5))


### Bug Fixes

* clarify version display and expand the about dialog ([71592fe](https://github.com/FOSScanner/fosscanner-app/commit/71592fed3f0f2af32555de41840250402dc77c83))
* corner role validation could reject valid, correctly-ordered crops ([e61972b](https://github.com/FOSScanner/fosscanner-app/commit/e61972b4892716366409d94df18705777f9fb59c))
* dedupe snackbar helper, guard a post-dispose setState, surface launchUrl failures ([c478ecb](https://github.com/FOSScanner/fosscanner-app/commit/c478ecb64aff8424ce4a08be024edf244cb97e4c))
* enable tryHarder so 1D barcodes (EAN/UPC/Code128) actually decode ([d0661ba](https://github.com/FOSScanner/fosscanner-app/commit/d0661bae8eb832f018bd93333da0e606736bf689))
* QR scan result never clears, and the found-code overlay looked clickable ([01c2c36](https://github.com/FOSScanner/fosscanner-app/commit/01c2c361b916d9b962c49a1932d4cc32b6e2fc3b))
* QR/barcode scanning never detecting a code ([1e92ad7](https://github.com/FOSScanner/fosscanner-app/commit/1e92ad76c256fcac45c0daf4c6b4849f6b174c53))
* reject corner quads with mismatched tl/tr/br/bl roles ([d726d4d](https://github.com/FOSScanner/fosscanner-app/commit/d726d4df7e77cd792bf9ff5164f73f1574ee412d)), closes [#20](https://github.com/FOSScanner/fosscanner-app/issues/20)
* show corner-adjust errors in a snackbar instead of shrinking the preview ([012d0fe](https://github.com/FOSScanner/fosscanner-app/commit/012d0fe10144b8aef596ea8c9334996ca2c34c3e)), closes [#21](https://github.com/FOSScanner/fosscanner-app/issues/21)
* use FOSScanner consistently in user-facing display strings ([600fbe0](https://github.com/FOSScanner/fosscanner-app/commit/600fbe0b5b320c657fcb03b28aba121127cecf3d))
* use_build_context_synchronously lint in _openResult ([e9c9fa3](https://github.com/FOSScanner/fosscanner-app/commit/e9c9fa304f9349e43218231dd19a8ef8199f277b))

## [1.2.2](https://github.com/FOSScanner/fosscanner-app/compare/v1.2.1...v1.2.2) (2026-08-26)


### Bug Fixes

* align platform configuration and CI
* harden image intake and sharing
* harden native document processing
* improve corner control accessibility

## [1.2.1](https://github.com/FOSScanner/fosscanner-app/compare/v1.2.0...v1.2.1) (2026-08-23)


### Bug Fixes

* keep release-please tags as plain vX.Y.Z, not component-prefixed ([9095fa9](https://github.com/FOSScanner/fosscanner-app/commit/9095fa95258b2dd363677c8b05c0b15167c4ba9e))

## [1.2.0](https://github.com/FOSScanner/fosscanner-app/compare/fosscanner-v1.1.0...fosscanner-v1.2.0) (2026-08-23)


### Features

* add page rotate, brightness/contrast, drag-reorder, and gallery import ([61c00ee](https://github.com/FOSScanner/fosscanner-app/commit/61c00eed0e0bb9094fdbaf28f8ce7f36da1a62ba))


### Bug Fixes

* pin release-please to main, not the repo default branch ([8d13f1f](https://github.com/FOSScanner/fosscanner-app/commit/8d13f1fc28c42f5d00bfb0a9ad26318e9c6d490d))

## [Unreleased]

## [1.1.0] - 2026-08-16

### Added

- Real document scanning: automatic edge detection (OpenCV via
  `opencv_dart`) with a draggable corner overlay to correct it, then
  perspective correction into a flat, upright page.
- Scan filters — Original, Auto-Enhance, Grayscale, Black & White — with
  live thumbnail previews before confirming.
- Re-edit a page's corners/filter after the fact without re-scanning it.

### Changed

- Release APKs are now split per-ABI (`arm64-v8a`, `armeabi-v7a`,
  `x86_64`) instead of shipping one universal APK, cutting the download
  most phones need from ~83MB to ~28MB.

### Fixed

- A native double-free in the edge-detection pipeline (disposing
  individual `findContours` result elements instead of the container they
  came from) that could crash the app on capture, most reliably on
  realistic (multi-megapixel) photos.

### Known limitations

- Edge detection, perspective correction, and filters are native-only
  (`opencv_dart` has no web support); the web build falls back to using
  the raw captured photo as-is.

## [1.0.0] - 2026-08-04

### Added

- Capture document pages with the device camera.
- Combine captured pages into a single PDF.
- Share the generated PDF via the OS share sheet, or download it directly
  on web when the Web Share API isn't available.
- Material 3 UI that follows the system's light/dark theme.

### Privacy

- Captured photos and generated PDFs are never persisted by the app:
  temp files are deleted as soon as a page is removed, the list is cleared,
  the app closes, or right after handing the PDF off to the share sheet.
