# Native dependency notices

These texts supplement Flutter's generated Dart-package notices and the OCR
notices in `assets/tessdata`. They are bundled assets and are registered in the
existing **About → View licenses** page. The original dependency sources are
not modified. Source comments are reproduced verbatim, including their original
copyright and license terms; this does not add licensing headers to app code.

| File | Source and scope |
| --- | --- |
| `BARCODE_NOTICES.txt` | Locked `flutter_zxing` 3.1.1 archive, SHA-256 `aba36b8235a3a985da7dc9e300be05b62ed0a8b1b27f04cbc299ef3246e70bc6`. Conservative notice superset of `src/zxing/core/src`, including quoted backend/header includes; no Zint frontends or test programs. Includes native Apache-2.0 and BSD-3-Clause notices, not just the wrapper MIT license. |
| `OPENCV_NOTICES.txt` | OpenCV 4.13.0 at `fe38fc608f6acb8b68953438a62305d8318f4fcd`. Android CMake-installed `sdk/etc/licenses` files, plus source/header notices for the modules observed in the successful ARM64 compilation database (`core`, `imgproc`, `imgcodecs`). Includes dependencies' companion README/IJG texts and OpenCV's historical BSD notices. |
| `KLEIDICV_NOTICES.txt` | KleidiCV 0.7.0 at `1e8fe7008c2292657b9689d70ea5d30db0e57767`: Apache-2.0 text and native source/header copyright notices. |
| `CAMERAX_NOTICES.txt` | CameraX `camera-core:1.6.2` source JAR's `META-INF/androidx/camera/camera-core/LICENSE.txt` (Google Maven), plus libyuv LICENSE, PATENTS and AUTHORS from official libyuv revision `03f119c01450d3c42f4902d66b77d18f7487c9a0`. CameraX's POM explicitly identifies embedded libyuv under BSD-3-Clause. This notice revision is **not** asserted to be the precise libyuv code revision in the Maven AAR. |

`provenance.json` records input file and generated text hashes and binds the
review to `pubspec.lock`. Keep this file in source control, not as a runtime
asset. Flutter's engine notices are already supplied through `sky_engine`:
all 1,594 individual license bodies in the pinned Flutter 3.44.0 engine LICENSE
were found in the decoded `NOTICES.Z` of the prior successful CI-image APK.
Do not ship a second copy of that entire engine notice set unnecessarily.

## Regeneration

Use Python's standard library and the **pinned local inputs** used by the recipe.
The OpenCV installed licenses and compilation database must come from the ARM64
Android build, not a Linux rehearsal. Obtain `camera-LICENSE` from the CameraX
source JAR above, and `libyuv-{LICENSE,PATENTS,AUTHORS}` using the pinned libyuv
revision (Gitiles `?format=TEXT` responses must be base64-decoded).

```sh
python3 tool/update_native_notices.py \
  --zxing /path/to/pub-cache/hosted/pub.dev/flutter_zxing-3.1.1 \
  --opencv /path/to/pinned/opencv \
  --opencv-licenses /path/to/android/install/sdk/etc/licenses \
  --opencv-compile-commands /path/to/android/compile_commands.json \
  --kleidicv /path/to/pinned/KleidiCV \
  --notice-inputs /path/to/extracted/camera-and-libyuv-notices
python3 -m unittest discover -s test/tool -p '*_test.py'
```

Regeneration is a review tool, not an automatic license compatibility decision.
Review new dependencies, modules, source revisions and terms before updating
hashes. Conservative source/header inclusion may retain notices for optional
native code; it does not claim that every mentioned component is linked.
Final packaging must compare these texts byte-for-byte with the chosen APK and
confirm their availability in the licenses UI. No update to this directory
changes an already built or released APK.
