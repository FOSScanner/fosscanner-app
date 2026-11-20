# Open-issue closure audit and UI follow-up

## Evidence and scope

Snapshot reviewed against `origin/dev` at **dd79468**. The initial inventory
contained **63 open issues**; **4 were closed with evidence**, leaving **59**.
This is a conservative triage, not a claim that every reported hardware problem
was reproduced. No fork screenshots, closed PR, pending branch, or passing widget
test is treated as proof of merged native-device acceptance.

### Verified closures

#77, #92, #100, and #101 were implemented in merged PR #126. Its quality,
Android, Android signing, and iOS checks passed. A fresh focused audit on Flutter
3.44.0 / Dart 3.12 reran draft filesystem/recovery, restoration/intake, reordering,
camera errors, memory/admission, and widget regressions: **85 tests passed**.
Each closure comment identifies its implementation and remaining related issues.

### Closed contributions are not merged fixes

GitHub reports `merged_at: null` for the closed #128–#131 base proposals and
#174–#193 contribution stack. #173's reported fork/emulator QA is useful context,
not evidence that the stack exists in `dev`. Its related issues must not be
bulk-closed. Focused contributions can be reviewed/adapted independently; the
batch-review groundwork here is adapted from @VincenzoImp's PR #130, with new
non-shrinking counter layout and additional regression coverage.

### Current follow-up decisions

- Prioritize the maintainer-authored batch-review gap (#91), then controls moving
  under the user's finger (#148/#154), and missing registered-license access
  (#135). No new dependencies, permissions, scan persistence, or network paths.
- Batch position is shown throughout review, with remaining-count semantics.
  Skip advances one image; Stop/Back from crop ends the batch and preserves
  accepted pages. Back from appearance still returns to crop first. Stop stays
  in its slot but disables when no images remain; Skip can finish the last item.
- An optional fast-review/accept-all path was evaluated and **not added**: it
  would bypass the current per-page crop/appearance approval and current-preview
  invariant. A separately designed opt-in flow is preferable to silent acceptance.
- Retain recovery live regions and retry actions while painting feedback inside
  the preview; do not reserve additional control rows that move sliders.
- Native/physical acceptance remains open. In particular, privacy cleanup (#157)
  and permission minimization (#127) are important independent follow-ups, not
  resolved by this UI work.

## Follow-up validation

Flutter 3.44.0 / Dart 3.12: `flutter analyze --no-pub` clean;
`flutter test --no-pub` **365 passed**. The focused review/layout/recovery plus
synthetic screenshot renderer run passed **61 tests**. `git diff --check` is
clean. The OCR-off/image-only-export test's obsolete subtitle expectation was
updated; behavioral assertions remain. Screenshots use synthetic documents.
PR #200 and #201 quality, Android, signing, and iOS checks are green; #201's
initial Kotlin artifact-resolution failure passed on one failed-job rerun
without code/toolchain changes. None of these checks establishes native-device
or physical accessibility acceptance.

## Disposition of every issue in the original snapshot

“Keep open” below means no verified completion sufficient for closure; it does
not assert that no partial work exists. Pending PRs must merge before their code
is counted as available on dev. Status is a point-in-time record.

| Issue | Disposition / evidence |
| --- | --- |
| [#199](https://github.com/FOSScanner/fosscanner-app/issues/199) — test(ui): validate responsive layouts and native UI on Android and iOS devices | Keep open: explicit Android/iOS native-device acceptance cannot be replaced by widget/golden tests. |
| [#198](https://github.com/FOSScanner/fosscanner-app/issues/198) — test(ui): add cross-device screenshot regression coverage | Keep open: asserted visual matrix and CI diffs are in unmerged PR #201, not dev. |
| [#197](https://github.com/FOSScanner/fosscanner-app/issues/197) — perf(ui): size image preview decoding for display density within memory limits | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#196](https://github.com/FOSScanner/fosscanner-app/issues/196) — ui: guarantee usable document previews and narrow-window action layouts | Keep open: useful-preview and narrow-control work is in unmerged PR #201. Full issue acceptance is not inferred from widget tests alone. |
| [#195](https://github.com/FOSScanner/fosscanner-app/issues/195) — ui: adapt page grid and editor layouts to width, tablets, and resizable windows | Keep open: PR #201 advances sizing/resizing. Obstructing-hinge policy and hardware evaluation remain. |
| [#194](https://github.com/FOSScanner/fosscanner-app/issues/194) — fix(ui): protect screen bodies from cutouts and make crop errors scrollable | Keep open: PR #200 is unmerged; CI passed. Physical notched-device landscape acceptance remains unperformed. |
| [#173](https://github.com/FOSScanner/fosscanner-app/issues/173) — Contribution series: 20 stacked PRs for intake, export, editor/home layout stability and QA fixes | Keep open as tracking/disposition work: #128–#131 and #174–#193 are CLOSED with merged_at=null. Fork implementation/QA is not merged dev evidence. |
| [#172](https://github.com/FOSScanner/fosscanner-app/issues/172) — design: product decisions from a first-time-user review | Keep open: product decisions are unresolved; no blanket acceptance/rejection is inferred. |
| [#171](https://github.com/FOSScanner/fosscanner-app/issues/171) — fix(intake): don't silently lose pages when the process dies during a review | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#170](https://github.com/FOSScanner/fosscanner-app/issues/170) — fix(home): editing a page in a large document is refused with a misleading message | Keep open: existing-page edit headroom/message issue is separate from the completed intake guidance (#100). |
| [#169](https://github.com/FOSScanner/fosscanner-app/issues/169) — ux(home): auto-scroll the page grid while dragging a page | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#168](https://github.com/FOSScanner/fosscanner-app/issues/168) — ui(editor): filter chip width, large-text button heights and screen-reader duplication | Keep open: PR #201 stacks crop actions, but chip width stability and semantic duplication/relative corner announcements remain. |
| [#167](https://github.com/FOSScanner/fosscanner-app/issues/167) — ui(editor): keep the page visible while the Filters sheet is open in landscape | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#166](https://github.com/FOSScanner/fosscanner-app/issues/166) — ui(editor): crop overlay tint, black-and-white edge artifacts, contrast slider centre and filter sheet scrim | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#165](https://github.com/FOSScanner/fosscanner-app/issues/165) — fix(export): minimal, consistent PDF metadata and no injected share text | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#164](https://github.com/FOSScanner/fosscanner-app/issues/164) — ux(home): reveal moved and newly added pages; double-tap to zoom the page preview | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#163](https://github.com/FOSScanner/fosscanner-app/issues/163) — ux(qr): recover from denied camera permission and give feedback for images without a code | Keep open: settings round trip, first/permanent denial distinction, and no-code gallery feedback go beyond completed #101. |
| [#162](https://github.com/FOSScanner/fosscanner-app/issues/162) — ux: report every rejected image in a multi-image import | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#161](https://github.com/FOSScanner/fosscanner-app/issues/161) — ux(editor): confirm before discarding unsaved edits and captures | Keep open: this follow-up does not implement general dirty-editor/capture discard confirmation. |
| [#160](https://github.com/FOSScanner/fosscanner-app/issues/160) — ui(home): page cards, export label and camera button at very large display and font sizes | Keep open: PR #201 addresses some grid/label sizing. FAB overlap at arbitrary scroll positions and largest-display device checks remain. |
| [#159](https://github.com/FOSScanner/fosscanner-app/issues/159) — ui(editor): usable landscape layout for the Adjust appearance step | Keep open: PR #201 adds side-by-side controls, but exact always-visible-primary-action cases still need validation. |
| [#158](https://github.com/FOSScanner/fosscanner-app/issues/158) — ux(editor): explain invalid crops in place and keep corner order consistent | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#157](https://github.com/FOSScanner/fosscanner-app/issues/157) — fix(privacy): remove share and image-picker copies of documents from the cache | Keep open, high-priority privacy follow-up: app-owned picker/share copy cleanup is not supplied by the closed unmerged series. |
| [#156](https://github.com/FOSScanner/fosscanner-app/issues/156) — fix(home): the camera button moves into the Undo spot after deleting a page | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#155](https://github.com/FOSScanner/fosscanner-app/issues/155) — fix(editor): corner and slider drags near the screen edge trigger system Back and discard the page | Keep open: body SafeArea (#200) is not Android system-gesture exclusion; exclusion computation and gesture-navigation acceptance remain. |
| [#154](https://github.com/FOSScanner/fosscanner-app/issues/154) — ui(export): keep the Searchable text subtitle the same length in both states | In this follow-up: one state-independent subtitle and switch/sheet/Done geometry assertions at small/standard phone widths and 100%/200% text. |
| [#153](https://github.com/FOSScanner/fosscanner-app/issues/153) — ui(home): keep page-card footers uniform and stop the drop-target border from shrinking the card | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#152](https://github.com/FOSScanner/fosscanner-app/issues/152) — ui(home): keep the export bar height constant across export states and page counts | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#151](https://github.com/FOSScanner/fosscanner-app/issues/151) — ui(home): keep app-bar actions and the camera button in place when the document becomes empty or non-empty | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#150](https://github.com/FOSScanner/fosscanner-app/issues/150) — ui(editor): keep the crop canvas the same size across review states and batch images | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#149](https://github.com/FOSScanner/fosscanner-app/issues/149) — ui(home): stop the draft-save failure banner from pushing the page grid down | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#148](https://github.com/FOSScanner/fosscanner-app/issues/148) — ui(editor): keep the preview and sliders in place while the preview status changes | In this follow-up: overlay feedback within the preview, gapless frame replacement, and geometry tests across pending/updating/failed/ready states. |
| [#147](https://github.com/FOSScanner/fosscanner-app/issues/147) — test: add a reusable layout-stability test harness | Keep open: shared geometry harness is in unmerged PR #201 and reused by this follow-up. No merged completion yet. |
| [#146](https://github.com/FOSScanner/fosscanner-app/issues/146) — ux: move brightness and contrast into an on-demand Adjust panel and add explicit empty-state actions | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#145](https://github.com/FOSScanner/fosscanner-app/issues/145) — feat: import pages from a PDF | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#144](https://github.com/FOSScanner/fosscanner-app/issues/144) — ux: remember and show the searchable-PDF choice | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#143](https://github.com/FOSScanner/fosscanner-app/issues/143) — build: give debug builds their own application ID | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#142](https://github.com/FOSScanner/fosscanner-app/issues/142) — ci: run the Kotlin unit tests and enforce dart format | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#141](https://github.com/FOSScanner/fosscanner-app/issues/141) — perf: share the exported PDF by file path instead of loading it into memory | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#140](https://github.com/FOSScanner/fosscanner-app/issues/140) — ui: remove filler copy and unify wording and icons across the app | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#139](https://github.com/FOSScanner/fosscanner-app/issues/139) — feat(android): hide document content from Recents and optionally block screenshots | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#138](https://github.com/FOSScanner/fosscanner-app/issues/138) — feat(android): copy recognized text | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#137](https://github.com/FOSScanner/fosscanner-app/issues/137) — feat(android): accept images shared into the app | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#136](https://github.com/FOSScanner/fosscanner-app/issues/136) — ux: carry the last chosen filter over to the next new page | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#135](https://github.com/FOSScanner/fosscanner-app/issues/135) — ui: link the open-source licenses page from About | In this follow-up: About link to Flutter LicensePage, existing bundled OCR notices, and 200%-text navigation coverage. |
| [#134](https://github.com/FOSScanner/fosscanner-app/issues/134) — ux: continue camera capture after adding a page (Add & scan next, Retake) | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#133](https://github.com/FOSScanner/fosscanner-app/issues/133) — feat(export): PDF page size and quality presets | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#132](https://github.com/FOSScanner/fosscanner-app/issues/132) — feat(export): save the PDF to device storage with a readable file name | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#127](https://github.com/FOSScanner/fosscanner-app/issues/127) — fix(privacy): remove microphone, storage and network-state permissions merged from plugins | Keep open, high-priority privacy follow-up: merged-release permission allowlist and required device checks are not verified complete. |
| [#103](https://github.com/FOSScanner/fosscanner-app/issues/103) — ui: prepare user-facing strings for future localization | Keep open as optional localization work; a reviewed language/RTL rollout has not been approved or implemented. |
| [#102](https://github.com/FOSScanner/fosscanner-app/issues/102) — ui: validate accessibility touch targets, contrast, focus, and status feedback across screens | Keep open: broad touch-target/contrast/focus/TalkBack/VoiceOver and real-platform acceptance is incomplete. |
| [#101](https://github.com/FOSScanner/fosscanner-app/issues/101) — ux: make document-camera permission failures as actionable as barcode errors | Closed as completed: PR #126 / 10e244b; safe supported permission/unavailability messages and Android/iOS mocked retry tests. |
| [#100](https://github.com/FOSScanner/fosscanner-app/issues/100) — ux: explain page limits, memory limits, and disabled intake actions accurately | Closed as completed: PR #126 / 1cc5cda; page/byte/source/processing/busy guidance and capacity recovery tests. |
| [#95](https://github.com/FOSScanner/fosscanner-app/issues/95) — ui: make the home grid, empty state, and About layout responsive | Keep open: responsive grid/layout work is in unmerged PR #201, not dev; device criteria remain. |
| [#92](https://github.com/FOSScanner/fosscanner-app/issues/92) — ux: make page reordering discoverable without requiring a hidden gesture | Closed as completed: PR #126 / dcadcb3; visible move menu, persistence, semantics, stale/locked callbacks, drag cancellation. |
| [#91](https://github.com/FOSScanner/fosscanner-app/issues/91) — ux: add batch-import context, Skip, and Stop controls to page review | In this follow-up: adapt the closed, unmerged PR #130 groundwork; add position/remaining semantics, Skip/Stop and Back behavior, cleanup and tests. Optional bulk fast review remains deliberately deferred. |
| [#90](https://github.com/FOSScanner/fosscanner-app/issues/90) — ui: validate and constrain the QR result panel on short screens and large text | Keep open: complete scrollable barcode review and 200%/short-screen tests already exist, but the explicit native camera-device check is not established. |
| [#80](https://github.com/FOSScanner/fosscanner-app/issues/80) — chore: simplify rotation normalization and clarify crop overlay behavior | Keep open: current dev still always repaints the quad and retains rotation cleanup work; fallback crop behavior has evolved, so do not blindly apply the old naming request. |
| [#79](https://github.com/FOSScanner/fosscanner-app/issues/79) — refactor: separate draft and export orchestration from scanner screen state | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#77](https://github.com/FOSScanner/fosscanner-app/issues/77) — fix: distinguish missing drafts from failed draft restoration | Closed as completed: PR #126 / 2e2d06d; restore failures, backup promotion, save protection, retry/discard regressions. |
| [#76](https://github.com/FOSScanner/fosscanner-app/issues/76) — perf: reduce eager work and repeated decoding in crop previews | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#75](https://github.com/FOSScanner/fosscanner-app/issues/75) — perf: encode JPEG once at the end of the document export pipeline | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
| [#74](https://github.com/FOSScanner/fosscanner-app/issues/74) — perf: avoid rewriting unchanged images on every draft save | Keep open: no verified merged completion satisfying the full issue; the closed contribution stack is not sufficient evidence. Requires focused implementation/validation. |
