# F-Droid preflight: native inputs (#209)

Starting inventory against `8530fa1` (v1.6.0 source), not an inclusion-policy
sign-off. A working upstream build can use caches and network access that the
F-Droid builder will not have.

**Signing decision (#208):** Use F-Droid signing for first inclusion. The recipe
must build an unsigned APK from source without upstream credentials. F-Droid
signs it for distribution; GitHub releases retain the existing upstream key.
Test F-Droid updates within that channel, not over a GitHub-signed install.

| Input | Evidence from the locked dependencies | Recipe work before submission |
| --- | --- | --- |
| [opencv_dart / dartcv4](https://github.com/rainyl/opencv_dart), both 2.2.2 | Apache-2.0 wrappers. In `dartcv4/src/CMakeLists.txt`, source mode defaults on; `FetchContent` takes OpenCV 4.13.0 (and, conditionally, opencv_contrib) from GitHub tag archives without a `URL_HASH`. The alternative download helper fetches **prebuilt** platform libraries. | Supply checksum-pinned source inputs; verify which modules and transitive downloads the ARM64 build actually uses with networking disabled. Do not switch to the prebuilt helper to bypass a failed source build. |
| [flutter_zxing](https://github.com/khoren93/flutter_zxing) 3.1.1 | MIT wrapper. The Android Gradle plugin points `externalNativeBuild` at the package's `src/CMakeLists.txt`; `src/zxing` contains native source. | Inventory vendored ZXing/Zint versions and notices separately from the wrapper license; trace optional CMake fetches. |
| [Tesseract4Android](https://github.com/adaptech-cz/Tesseract4Android) 4.9.0 | App uses a JitPack dependency. The resolved AAR (SHA-256 `bce5d6413a1a5ae3d7240033fbbc851ba3217d0a08d9769400e17a077f42cb2a`) already contains ARM64 `libtesseract`, `libleptonica`, `libjpeg` and `libpngx`. | Map binaries to source revisions and codec licenses. Confirm the artifact is acceptable or build from source; do not add a broad scanner exception. |
| Bundled Latin OCR model | Local SHA-256 matches the pinned [asset record](../../assets/tessdata/README.md). `pubspec.yaml` includes its license and native third-party notices. | Verify the notices in the candidate APK, not only in the source tree. |

Still outstanding: Flutter/Android toolchain and remaining transitive artifacts,
fonts and artwork, restricted-network build, and F-Droid source/binary scan on
the exact proposed revision. Missing evidence is not a finding of a non-free
license. Resolve these alongside signing (#208) before accepting the recipe
(#210); installation and upgrade testing (#211) need the actual signed candidate.

## Local packaging evidence (not an F-Droid build)

A clean archive of `8530fa1` plus the local unsigned Gradle change, using the
locked pub dependencies, produced an unsigned ARM64 APK with SHA-256
`8b9fc7f7a9d88eba354ae33f7d87c91902fea6d1afb165a3f751c4b9c5f661d6`.
`aapt` reported `com.fosscanner.app`, `1.6.0`, version code `2011`, and only
`arm64-v8a`. `apksigner verify` reported `Missing META-INF/MANIFEST.MF`.
The ARM64 merged manifest passed `tool/check_android_permissions.py`; the APK
requested only CAMERA and its own receiver permission. The packaged Latin
model, license and native notices matched the tracked files byte-for-byte.

For #210, the fdroiddata `master` metadata path `metadata/com.fosscanner.app.yml`
returned 404. GitLab API title/description searches for `fosscanner` returned
no matching fdroiddata merge requests or F-Droid RFP issues. Recheck before
submission: this is a name search, not proof no one is packaging the app.
Do not point a recipe at vanilla v1.6.0 and expect the local unsigned option;
it needs a public source revision containing the change or a reviewed recipe patch.

## ARM64 OpenCV: offline native configuration test

The app's DartCV hook built from source with `imgcodecs` and `imgproc` enabled
(`core` is implicit). Fresh downloads from these upstream URLs matched the
SHA-256 values observed during the APK build:

| Input | SHA-256 |
| --- | --- |
| [OpenCV 4.13.0 source](https://codeload.github.com/opencv/opencv/tar.gz/refs/tags/4.13.0) | `1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d` |
| [KleidiCV 0.7.0 source](https://gitlab.arm.com/kleidi/kleidicv/-/archive/0.7.0/kleidicv-0.7.0.tar.gz) | `9fbdeb04acab774a7d74344a714453400e7ec8fae4c2b6c6ba2f78656ca429ab` |

With `docker run --network none`, an empty CMake build directory, and no
OpenCV download cache, verify the archives **before extracting**, unpack OpenCV
into `/tmp/opencv-4.13.0`, and put `kleidicv-0.7.0.tar.gz` in `/inputs/`. The
following additions to the DartCV 2.2.2 hook's normal CMake configure command
worked with NDK 28.2.13676358, CMake 3.22.1, Ninja 1.10.2, ARM64/API 24:

```text
-DFETCHCONTENT_SOURCE_DIR_OPENCV=/tmp/opencv-4.13.0
-DFETCHCONTENT_FULLY_DISCONNECTED=ON
-DOPENCV_KLEIDICV_URL=file:///inputs/
```

The final slash matters: OpenCV appends the archive filename. CMake generated
`opencv_core`, `opencv_imgcodecs`, and `opencv_imgproc` dependencies with the
KleidiCV HAL enabled. `cmake --build <build-dir> --parallel 2 --target kleidicv_thread`
then compiled and linked both ARM64 KleidiCV static libraries (120 Ninja steps).
This tests native configuration and that target only, not a full offline APK.
The fdroiddata recipe still needs to provision these inputs and pass the settings
through the Flutter native hook, which constructs its own CMake invocation.

## OCR: source mapping

[Wrapper tag 4.9.0](https://github.com/adaptech-cz/Tesseract4Android/tree/15c534717b1cb58261b58d4e4c1200c7f81f668c)
resolves to the same commit referenced by the [shipped notices](../../assets/tessdata/THIRD_PARTY_NOTICES.txt).
Its README identifies Tesseract 5.5.1, Leptonica 1.85.0, IJG libjpeg 9f, and
libpng 1.6.48. Its `tesseract4android/src/main/cpp/CMakeLists.txt` adds all four
vendored source directories. This identifies a source-build route for the four
ARM64 libraries found in the AAR; it does not verify the JitPack binaries or
establish their acceptance. Next test the standard (non-OpenMP) Android library
from that commit as a substitute for the JitPack dependency in the recipe.

The separate OCR source probe linked `libjpeg.so`, `libpngx.so`,
`libleptonica.so`, and `libtesseract.so` with networking disabled. Host `file`
inspection confirmed all four are AArch64 ELF shared libraries for Android 21
(NDK r28c). The container's post-build inspection command lacked `file`; the
native link completed, but this was not a successful end-to-end AAR or APK test.

### Offline Android library build

Using the same wrapper commit, the `standardRelease` Android library (AAR)
built with Docker networking disabled and Gradle `--offline`. This was an
isolated build, not an F-Droid builder run. Recipe inputs and adjustments:

- The [source archive](https://codeload.github.com/adaptech-cz/Tesseract4Android/tar.gz/15c534717b1cb58261b58d4e4c1200c7f81f668c)
  had SHA-256 `888318d957ac57e765dcb676b510ead65028613d40d448ff53b827824896d289`.
  Extract to a writable build directory (the Leptonica CMake project writes a
  lock file there).
- Include only `:tesseract4android` in the standalone Gradle project. Use the
  app's Gradle 9.1.0 wrapper, AGP `com.android.tools.build:gradle:9.0.1`, app
  Gradle properties and upstream `ext.tesseract4AndroidVersion = '4.9.0'`.
  Keep compile SDK 35 and CMake 3.22.1; select NDK 28.2.13676358 and
  `abiFilters 'arm64-v8a'` in the library module. Build
  `:tesseract4android:assembleStandardRelease`, not the OpenMP variant.
- Provision the Java wrapper dependency `androidx.annotation:annotation:1.3.0`
  from Google's Android Maven repository before disabling the network. The
  first offline Java compile failed because only its metadata was cached. The
  downloaded JAR matched the module metadata SHA-256
  `97dc45afefe3a1e421da42b8b6e9f90491477c45fc6178203e3a5e8a05ee8553`;
  a local Maven input restricted to that single coordinate resolved it.
- Result: `tesseract4android-standard-release.aar`, SHA-256
  `ac0c1da260b1bed58181e9aed440dc917bef1603abe525f2df9b4d423e380abc`
  (identifies this run, not a reproducibility guarantee). Inside `classes.jar`
  the three wrapper classes the app imports were present: `TessBaseAPI`,
  `TessPdfRenderer`, and `ReadFile`. The AAR contained all four expected JNI
  libraries and no other ABI; each ELF header identified 64-bit AArch64.

The first app integration attempt replaced the JitPack dependency with this
locally built AAR in a scratch copy, leaving upstream signing and dependencies
unchanged. With networking disabled the Flutter hook still attempted to fetch
OpenCV 4.13.0 from GitHub; Gradle offline mode alone does not control the hook.
For the retry, the scratch copy of `dartcv4/src/CMakeLists.txt` sets the three
local-source options above inside `if(DARTCV_BUILD_OPENCV_FROM_SOURCE)` before
`FetchContent` runs. Do not count the previous APK in the warm workspace as a
successful build: require a successful `assembleRelease` and verify that the
four packaged JNI libraries come from the source-built AAR.

### Integrated APK result

The retry succeeded under `--network none` with Gradle `--offline`:
`:app:assembleRelease` completed (53 tasks executed, 334 up-to-date). The
unsigned APK SHA-256 was `2dc975e539cc2ff0a5fd48481a169f9d154a2e46aea3bb9dd7f558e703a40192`.
Each of `libjpeg.so`, `libpngx.so`, `libleptonica.so` and `libtesseract.so` in
its `lib/arm64-v8a/` directory matched the corresponding `jni/arm64-v8a/` AAR
entry byte-for-byte. `aapt` reported `com.fosscanner.app`, 1.6.0 (2011), ARM64
only; `apksigner` reported `Missing META-INF/MANIFEST.MF`. The packaged manifest
passed the permission allowlist. This proves the substitution reached the APK,
not that a clean F-Droid builder can bootstrap it or that OCR runs on hardware.

### F-Droid scanner preflight (#209 / #210)

Tool: `fdroidserver` 2.4.5, refreshed SUSS database SHA-256
`ffc98ab9d588c3defb29ea59e3c8c43215075080a210fe1805fa6278e1133bd4`.
`fdroid scanner --exit-code <apk>` ran build-tools 36.0.0 `dexdump` and checked
extra signing blocks on the integrated APK above: exit 0, no reported findings.
This binary scan is not a native code or licensing audit.

In disposable copies (no `scanignore` or `scandelete` rules):

1. Scanned the tracked app sources at `8530fa1` with the unsigned Gradle change:
   no problems. Adding the extracted OpenCV, KleidiCV and Tesseract4Android
   source archives produced **27 errors and 2 warnings**. Inspect the structured
   `errors` and `warnings` arrays from `fdroid scanner --json`, not just the
   process exit status. The scanner also removed upstream Gradle wrappers.
2. Reviewed and moved the following out of the disposable input tree. These
   are not the Android library sources. Paths relative to OpenCV: `apps/pattern-tools/DICT_*.json.gz`
   (21), `modules/js/{perf,test}/package.json`, `doc/js_tutorials/js_assets/webnn-electron/package.json`,
   `samples/java/sbt/sbt/sbt-launch.jar`, and `modules/java/test/pure_test/lib/junit-4.11.jar`.
   Relative to Tesseract4Android: the three ZIP seed corpora in
   `tesseract4android/src/main/cpp/leptonica/src/prog/fuzzing/`. The rescan passed.
3. Added fresh pub.dev archives for `dartcv4`, `opencv_dart`, and `flutter_zxing`
   after checking each SHA-256 against `pubspec.lock`; rescanned the combined
   tree: **0 errors and 0 warnings**. These are selected native dependencies,
   not the entire Flutter/Gradle dependency graph.

The APK build preceded that source pruning. Next: encode these inputs in the
recipe, rebuild from the same pruned tree with an empty project build directory,
and rerun both scans on that build. No APK or policy exception has been submitted.

## Candidate permission gate (#127 / #211)

Run against the **exact APK** being evaluated, including the F-Droid-signed
artifact once available. From the repository root with Android SDK command-line
tools installed:

```bash
set -e
sha256sum "$apk"
"$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" manifest print "$apk" > candidate-manifest.xml
python3 tool/check_android_permissions.py candidate-manifest.xml
```

Record the digest alongside the result. The local unsigned ARM64 APK identified
above passed the packaged-manifest check. This is not device acceptance: on API
28 and a current Android release, record the model/API, candidate digest, and
pass/fail for camera accept/cancel, denied-camera recovery, barcode scan, single
and batch gallery import, and PDF sharing. Use synthetic pages; record untested
cases rather than inferring results from permission declarations.

## Draft fdroiddata recipe (#210)

The [recipe and patch](../../contrib/fdroiddata/README.md) target the public
v1.6.0 commit rather than an unpushed branch. The source patch applies to a
fresh archive. It builds the OCR Gradle module in the app's dependency graph,
so no local AAR has to be supplied to the builder. OpenCV uses the external
KleidiCV source tree. `fdroid rewritemeta` and `fdroid lint` ran with
fdroidserver 2.4.5 and the current fdroiddata category configuration (`OCR`).

A disposable rehearsal used the recipe's commands on a fresh app tree,
lockfile-enforced pub packages, and native sources from the previously checked
archives at the pinned revisions. Scanning the populated pub cache identified
nine example Gradle files that were not covered by the earlier three-package
sample. The prepared sources passed a verbose source scan with **0 problems**
after removing those specific example scripts. The network-disabled build uses
a provisioned Flutter/Android SDK and Gradle dependency cache (including the
verified AndroidX annotation input); it is not an empty-cache bootstrap or an
`fdroid build --server` result.

### Result for the source-scanned tree

Starting with no app build outputs, the ARM64 release build completed with
networking disabled. The first attempt stopped at `:app:mergeReleaseNativeLibs`:
our **local** Gradle mirror intercepted `androidx.annotation:annotation:1.10.0`
but provided only 1.3.0. On retry we restricted the mirror's Gradle content
filter to `includeVersion('androidx.annotation', 'annotation', '1.3.0')` so the
other version could resolve from the provisioned Google Maven cache. The app,
recipe sources and network policy did not change. The retry reused compilation
outputs from the first attempt; this is not a reproducibility comparison.

| Check on the resulting APK | Result |
| --- | --- |
| SHA-256 | `f7648f7e6f9e8cc80cf788dc47252e7695f9680fda3ba524ce94cecb5ff975cb` |
| Package / version / ABI | `com.fosscanner.app`, `1.6.0` (`2011`), `arm64-v8a` only |
| Signing | Unsigned packaging input: `apksigner verify` rejected it (`Missing META-INF/MANIFEST.MF`). |
| Packaged permissions | The manifest decoded from this APK passed `tool/check_android_permissions.py`. |
| OCR native inputs | The ELF build IDs of all four packaged JNI libraries matched the `:tesseract4android` **standardRelease** module's build outputs. |
| OCR model and notices | `Latin.traineddata`, `LICENSE` and `THIRD_PARTY_NOTICES.txt` inside the APK matched the tracked files byte-for-byte. |
| F-Droid binary scan | `fdroid scanner --exit-code` ran `dexdump` and checked extra signing blocks; exit 0. |

A separate v1.6.0 checkout with the same recipe patch and locked packages
passed static analysis, all **434 Flutter tests** and all **15 permission-tool
unit tests**. The Flutter tests ran on Linux, not on an Android device. This
local candidate is **not** a signed F-Droid release. Next distribution gate: run the recipe on a configured
F-Droid build server and repeat the artifact checks on its output.

### Native inventory of the scanned APK (#209)

All eleven ARM64 shared objects in the APK above were mapped to release inputs.
A build-ID match relates binaries across symbol stripping; it is not a claim of
byte-for-byte reproducibility.

| Packaged libraries | Observed origin / comparison |
| --- | --- |
| `libapp.so`, `libdartcv.so` | ELF build IDs matched the app's Dart AOT `app.so` and DartCV's CMake installation output, respectively. |
| `libdartjni.so`, `libflutter_zxing.so` | Byte-identical to the stripped ARM64 outputs of the `jni` and `flutter_zxing` Gradle modules. |
| `libjpeg.so`, `libpngx.so`, `libleptonica.so`, `libtesseract.so` | Build IDs matched the source-built OCR module, not the copies in the cached JitPack 4.9.0 AAR. |
| `libimage_processing_util_jni.so`, `libsurface_util_jni.so` | Byte-identical to entries in `androidx.camera:camera-core:1.6.2`. These came from an AAR, not the app's native compiler. |
| `libflutter.so` | Build ID matched the engine in `io.flutter:arm64_v8a_release:1.0.0-4c525dac5ebe5971c5708ef73558ed8edcf4a362`. This is a prebuilt engine. |

Android build-tools 36.0.0 `zipalign -c -P 16 4` passed. Every packaged ELF
had an alignment of at least 16 KiB for every `PT_LOAD` segment, with congruent
file offsets and virtual addresses. These are static checks, not a run on a
16 KiB-page device. Review the prebuilt CameraX/Flutter origins in the F-Droid
builder context; this inventory alone does not establish inclusion approval.

Fresh downloads from [Google Maven](https://dl.google.com/android/maven2/androidx/camera/camera-core/1.6.2/camera-core-1.6.2.aar)
(CameraX AAR, SHA-256 `ebd66f090414f4c12f23a55b5023aeee1b096da8a06c02a0b6fb3520c4ddadf6`)
and the [Flutter Maven repository](https://storage.googleapis.com/download.flutter.io/io/flutter/arm64_v8a_release/1.0.0-4c525dac5ebe5971c5708ef73558ed8edcf4a362/arm64_v8a_release-1.0.0-4c525dac5ebe5971c5708ef73558ed8edcf4a362.jar)
(engine JAR, SHA-256 `cf0f366cb9d39dffc79005433d9a8e931303daaa90d61b5624890e3c9561d6b8`)
matched the resolved build inputs byte-for-byte. CameraX's POM lists Apache-2.0
and BSD-3-Clause and points to `platform/frameworks/support`. Its AAR's Apache
license text is present in the decoded Flutter `NOTICES.Z`; this does not
establish that every native third-party attribution is covered.

### Check against current fdroiddata submission rules

At fdroiddata `74317e8e6293c095a0032d98a4f54b1c3c9895e1`, the app ID and the
two proposed new srclib names were unused. The existing `flutter` and `opencv`
srclibs matched the recipe. A fresh FOSScanner name search returned no matching
fdroiddata issue, merge request or RFP issue; recheck before submission. The
new-app checklist requests an author name and prefers upstream submodules. The
draft now identifies FOSScanner as author and explains why this public tag uses
pinned srclibs and F-Droid signing in its maintainer notes.

In a checkout of that fdroiddata revision, `rewritemeta`, `lint`, `yamllint`,
the upstream git-redirect check, and `checkupdates --allow-dirty --auto` completed
without changing the staged recipe. Upstream's job-selection script selected
`com.fosscanner.app:2011`. Metadata and update checks used fdroidserver
`fc2c86473e66a44fc641f403c338a8b2cccfad88` (verified descendant of the CI
trust anchor). The [submission draft](../../contrib/fdroiddata/submission.md)
keeps policy review and device acceptance open. These checks do not create a
GitLab pipeline, submission, or signed release.

### CI-image provisioning and store metadata follow-up

The local `fdroid build --test --on-server --scan-binary` run uses the upstream
`buildserver-trixie` image digest `sha256:1ea8bef1820bff06c2974e31b4fc4c79c364cd24231b86e71fa4b926797e0dac`.
Its first NDK download stopped progressing before installation. Resuming the
same upstream archive, checking it against sdkmanager's signed checksum list
(SHA-256 `dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f`
and matching SHA-512), and retrying allowed F-Droid to install r28c and enter
prebuild. This is a toolchain provisioning recovery, not an APK pass.

The upstream Fastlane **working tree** now documents image-only vs. opt-in OCR,
that sharing keeps the draft without a prompt, and that temporary copies may
remain. A local F-Droid metadata import read the English title, summary,
description, version-code `2011` release notes, icon and three synthetic UI
screenshots. These listing changes are not part of the immutable v1.6.0 tag.
Select a public upstream revision containing the corrections (and revalidate it)
before claiming the submitted listing includes them.

Once the F-Droid CI image installed the NDK and bootstrapped Flutter's tools,
its source scan found two errors not present in the warm-SDK rehearsal:
`analyzer-10.1.0/example/ddd06.exe` and `archive-3.6.1/web/res/readme.zip`.
There were also 25 warnings under `archive-3.6.1/test/tests/res`. Both versions
are pinned by **Flutter's own** `packages/flutter_tools/pubspec.yaml`; they are
not replacements for the app's locked packages. The recipe now drops only
these tool example/test fixtures before scanning. Using fdroidserver
`fc2c86473e66a44fc641f403c338a8b2cccfad88`, a verbose rescan of a copy of
that job's prepared sources with the recipe cleanup applied reported **0
problems**. This is source-scan evidence, not a binary scan of a new artifact.

## Milestone reached: CI-image build

The subsequent local run of `fdroid build --test --on-server --scan-binary`
succeeded. See the [milestone record](fdroid-build-milestone.md) for the exact
APK, independent verification, signing-guard tests and remaining gates. Earlier
probe hashes and failure states in this history are not the final artifact.
