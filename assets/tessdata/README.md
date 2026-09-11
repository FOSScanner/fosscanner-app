# Bundled OCR data

`Latin.traineddata` is the unmodified Latin-script LSTM model from
[tesseract-ocr/tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast)
at revision `87416418657359cb625c412a48b6e1d6d41c29bd`.

- Source: https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/87416418657359cb625c412a48b6e1d6d41c29bd/script/Latin.traineddata
- SHA-256: `6dbdaf8ecc6c40f025c2648bf3b3f3fbffe073e1fd2df2047fde2e2b2f020d53`
- Size: 89,384,811 bytes (about 85.24 MiB), before APK compression.
- License: Apache-2.0, reproduced in `LICENSE`.

Android streams the asset from the APK to private app storage and verifies its
checksum before atomically installing it. No model is downloaded at runtime.
Keep the asset name and checksum synchronized with `OcrModelStore.kt`.

This model covers Latin-based languages, excluding Vietnamese. It is not a
universal language detector and does not cover arbitrary scripts. Recognition
quality depends on the input; multilingual Android device validation remains
required. See `docs/ocr-development.md` for the initial comparison.

The existing local `eng.traineddata` prototype asset is not bundled by
`pubspec.yaml`. Its checksum was verified against the same upstream revision:
`7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2`.

`THIRD_PARTY_NOTICES.txt` reproduces the native OCR dependency license texts
from Tesseract4Android 4.9.0 (source revision
`15c534717b1cb58261b58d4e4c1200c7f81f668c`): Tesseract4Android and Tesseract
(Apache-2.0), Leptonica (BSD-2-Clause), libpng (libpng license), and libjpeg
(IJG license). Android also supplies system libraries such as zlib and libc++.

These files are bundled as Flutter assets alongside the model. The app's
existing Flutter dependency notices remain separate. The model provenance
and these notices do not replace final artifact and dependency verification.
