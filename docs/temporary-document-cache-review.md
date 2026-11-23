# Temporary document copies: source review for #157

Reviewed against dev `a67e4ba`, with `share_plus 13.3.1`,
`share_plus_platform_interface 7.2.0`, and `image_picker_android 0.8.13+19`.
This is source-level evidence, not a new emulator/device reproduction. No cache
cleanup behavior has been changed by this review, and #157 remains unresolved.

## Copies that need distinct ownership and lifetimes

1. `ScannerHomePage._sharePdfBytes` passes a data-backed `XFile`.
   `MethodChannelShare._getFile` writes it under a UUID directory in the app's
   temporary directory. This staging file is separate from Android's share cache.
2. Android `Share.getUrisForPaths` copies that file into `cache/share_plus` and
   publishes a `FileProvider` content URI. `clearShareCacheFolder` runs at the
   next share; it is not a sweep of the Dart-side UUID staging directories.
3. Android image picking copies a content URI into `cache/<uuid>/<filename>`;
   resizing can create another `cache/scaled_<filename>` file. The app currently
   preserves gallery paths because a picker return path must not be assumed to
   be a disposable copy on every platform.
4. OCR jobs use their own `fosscanner_ocr_` directory and clean it in `finally`.
   This does not establish cleanup of plugin-owned copies or crash leftovers.
5. Draft generations are intentional cached data, protected by the draft-session
   ownership/recovery design. They must not be included in a generic temp sweep.

## Why immediate deletion / a broad UUID sweep is unsafe

The Android share result reports chooser interaction, not an acknowledgement
that a receiving app has finished reading every PDF byte. The plugin callback
has no file-consumption completion signal. Deleting the published share-cache
file immediately when the Dart future returns is therefore not justified by
this API contract. It could break a receiver opening the URI asynchronously.

Both the picker and sharing platform interface use UUID directory names. A
UUID-shaped path alone is not sufficient proof of picker ownership. A startup
sweep also must not delete paths needed by `retrieveLostData`, a pending batch,
an OCR job, the active draft session, or another still-valid share.

## Required implementation boundaries

- Resolve the actual platform cache roots, not a guessed `/tmp` or path substring.
- Never delete a gallery original or follow symlinks outside those roots. Test
  traversal, prefix collisions, symlinked parents/files, missing files, and
  unrelated cache contents with real filesystem fixtures.
- Treat Dart share staging and native published share copies separately. An
  explicitly owned staging file can be removed once the native copy is known to
  exist; the published URI needs a separately documented retention policy.
- Protect pending Android picker recovery before considering startup cleanup;
  test process death and interrupted batches instead of sweeping first.
- Use bounded, identifiable ownership. Do not recursively delete the whole cache
  or assume all UUID directories belong to this feature.
- Distinguish successful cleanup from best-effort failure without logging scan
  contents or personal filenames. Update README/SECURITY only with behavior that
  is actually implemented and verified.

## Remaining acceptance

A focused implementation still needs matchers/ownership tests, safe integration
with import/clear/startup, an explicit share lifetime decision, and device checks
that a receiving app can open/read the PDF after the chooser returns. Existing
source evidence is not sufficient to close the issue or to claim that Clear all
currently removes every temporary document copy.
