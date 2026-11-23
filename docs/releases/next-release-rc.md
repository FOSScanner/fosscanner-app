# Next release: candidate preparation

Status: **local preparation only; not approved for stable publication**.
Prepared on 2026-11-23 UTC. No new APK, tag, release, push, or promotion to main
is implied by this document.

## Candidate identity and version

| Item | Baseline |
| --- | --- |
| Candidate application source | `88e808fcba868c83e33b9c07ad3820337d0a058c` (`dev`) |
| Preparation branch | `release/next-rc-preparation` |
| Latest published release at preparation | `v1.5.2` |
| Source version metadata | `1.5.2+10`, deliberately unchanged |
| Toolchain | Flutter 3.44.0 / Dart 3.12; Java 17 |
| Android production application ID | `com.fosscanner.app` |
| Final merged-source CI | [45150600921](https://github.com/FOSScanner/fosscanner-app/actions/runs/45150600921) |

The fetched dev baseline is 28 commits ahead of main and zero behind. This is
not a count of user-facing features. The preparation branch adds documentation
only; record its resulting commit separately when building an artifact.

The next version is **not assigned**. Release Please must generate the version,
build number, and changelog through the normal main workflow. The history
contains a `feat` entry, so 1.6.0 is possible; do not manually declare 1.5.3 or
rewrite generated files. Review the final feature set rather than advertising
intermediate behavior later removed (for example, visible page-reorder menus).

## Included scope

- #126: protect cached drafts after restore/read failures, support explicit
  retry/discard, and improve camera/intake error handling and guidance.
- #200 and #201: safe-area handling, scrollable crop errors, responsive document
  layouts, and bounded screenshot/layout regression coverage.
- #202: preserve batch review position/remaining context and Skip/Stop behavior;
  stabilize appearance-preview feedback and expose registered licenses in About.
- #203: compact page previews and controls; remove persistent hints and keep OCR
  options beside export at narrow widths and large text sizes. Accessible page
  reorder actions remain; do not promise a visible reorder menu.
- #207: remove unused merged microphone/storage/network-state permissions and
  enforce the processed release-manifest permission allowlist in CI.
- Dependency updates: flutter_zxing 3.1.1, image 4.13.1,
  camera_platform_interface 2.15.1, and actions/setup-java 6.3.0.
- Verify setup-java's exact approved immutable revision in the workflow policy
  test; the missing allowlist entry was corrected before merging #204.

## Draft user-facing release notes

### More reliable document review

- Recover from draft-loading failures with explicit retry or confirmed discard,
  without silently replacing an unreadable draft.
- Get clearer camera failures and batch-review position, with Skip and Stop
  actions that preserve already accepted pages.
- Use document previews and export controls that adapt better to smaller
  windows, landscape, display cutouts, and larger text.
- Keep appearance controls steadier while previews update or need retry, and
  open third-party license information from About.

### Android privacy and maintenance

- Remove unused microphone, storage, and network-state permissions contributed
  by dependencies; add a build-time permission allowlist to detect regressions.
- Update image decoding and barcode dependencies.

Scans and OCR remain on-device. This release does **not** claim complete cleanup
of temporary import/share copies: #157 remains unresolved. Do not equate Clear
all with deletion of every plugin-created cache file. The separate
[temporary-copy review](../temporary-document-cache-review.md) explains ownership
and share-lifetime constraints.

These notes are a draft, not a replacement for Release Please's generated
changelog or evidence of device acceptance.

## Automated evidence

The final merged-source run linked above completed successfully for
`88e808fcba868c83e33b9c07ad3820337d0a058c`, verified on 2026-11-23 UTC.
All four jobs passed: quality (Flutter analysis/tests and Python permission-tool
tests), Android (including the release-manifest permission allowlist), Android
release-signing verification, and the iOS no-codesign build. This establishes
CI acceptance of the selected application source, not production-device acceptance.

Before merging, #204, #205, and #206 each passed quality, Android, release-signing
verification, and iOS build jobs. #204 required the exact verified setup-java tag
SHA to be added to the test allowlist; a rerun before that correction reproduced
415 passing tests and one policy-test failure. Its corrected full run
[45146531967](https://github.com/FOSScanner/fosscanner-app/actions/runs/45146531967)
passed. These are historical CI results, not a newly built candidate APK or
hardware acceptance.

- [x] Record successful conclusion of final merged-source CI, exact SHA, and URL.
- [x] Confirm Flutter analysis, Flutter tests, Python permission-tool tests,
      Android build/manifest allowlist, release-signing check, and iOS build pass.
- [ ] Review the final source delta and generated release metadata for regressions.
- [ ] If application code changes, select a new baseline and rerun relevant checks.

## Stable-release blockers and dispositions

- [ ] **#157: temporary document-copy retention.** Recommended stable-release
      blocker. Implement and verify a safe ownership/lifetime policy, or obtain
      an explicit maintainer risk disposition with accurate user-facing wording.
      Never delete shared files solely because the chooser callback returned,
      sweep all UUID directories, or delete gallery originals.
- [ ] **#127: device validation of permission minimization.** #207 supplies the
      manifest removals and CI allowlist; the issue remains open. Verify camera,
      barcode, gallery, and sharing on API 28 and a current Android version.
- [ ] **#199 / #102: candidate-specific device and accessibility acceptance.**
      Reuse applicable Android/iOS evidence only when source/build identity matches.
- [ ] Review open data-loss/intake/system-gesture issues (including #171 and #155)
      against the candidate. Record reproduced impact and release disposition;
      do not imply every open enhancement must block publication.

No issues are closed by this preparation document.

## APK build gate (separate approval required)

- [ ] Obtain approval for a specific candidate build and target platform/ABI.
- [ ] Record clean build commit, Flutter version, build name/number, and mode.
- [ ] Choose the established production signing identity for an in-place upgrade;
      do not expose or commit signing material or bypass upstream signing checks.
- [ ] If using an isolated preview identity, label it clearly; it cannot establish
      production upgrade compatibility. See open debug-identity issue #143.
- [ ] Use a monotonic packaged version code. Source build number is currently 10;
      Flutter split-ABI APKs apply offsets, so inspect actual packaged values.
- [ ] Record artifact path, SHA-256, size, application ID, version name/code, ABI,
      minimum/target SDK, and signing certificate; verify the APK signature.
- [ ] Compare the certificate to the previous production APK before upgrade tests.

Do not uninstall or clear storage to bypass a signature mismatch. Export important
documents first. Existing local build outputs and old RC previews are not evidence
of an artifact built from this baseline.

## Candidate device acceptance

Use synthetic documents only. For each row record device/OS/ABI, APK SHA-256,
source SHA, settings, result, and notes. Failures and untested cases stay explicit.

| Scenario | Required checks | Result |
| --- | --- | --- |
| Install/upgrade | actual candidate, previous production certificate, drafts retained | Not performed |
| Capture/permissions | accept/cancel, denial/retry, gallery usable afterward, API 28/current | Not performed |
| Batch/gallery | single/multiple images, Skip/Stop/Back, position, accepted-page retention | Not performed |
| Crop/native processing | four edge handles, fallback/full image, rotate, filters, retry/current-preview saving | Not performed |
| Draft recovery | restart, persisted order, failed restore retry/discard, save retry, clear, final-page Undo | Not performed |
| Export | image-only default, opt-in offline OCR, cancellation, valid PDF, share/dismiss | Not performed |
| Cache/privacy | inspect owned picker/share copies and receiving-app reads; verify #157 disposition | Not performed |
| Barcode | permission failures, camera, long result, safe link review | Not performed |
| Accessibility/layout | TalkBack, 200% text, landscape/cutouts, narrow windows, reachable controls | Not performed |
| iOS (if released) | camera, picker, VoiceOver, layout, sharing and iPad popover | Not performed |

## Promotion and publication sequence

1. Complete final-source CI and resolve/disposition blockers above.
2. After separate build approval, build and accept an identifiable candidate.
3. Obtain release approval; open/review the normal dev-to-main promotion PR.
   Preserve feature/fix history used by Release Please. Do not promote merely to
   obtain a version number before acceptance.
4. Review Release Please's generated version/build number/changelog and release
   PR. Any substantive source changes require renewed candidate validation.
5. After approval, use the normal release workflow. Verify tag/source alignment,
   signed APK metadata/hashes, previous-certificate continuity, and final
   installation/upgrade. Record binary evidence separately from CI attestations.
6. Update download/preview wording only when assets are actually downloadable.

F-Droid inclusion is a separate workstream tracked in #213 (#208–#212). A GitHub
release does not establish F-Droid build compliance or availability. This document
does not authorize a push, promotion, tag, workflow dispatch, or publication.
