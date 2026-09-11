# Security Policy

## Supported versions

Only the latest release is supported. FOSScanner is a small, fast-moving
project without long-term-support branches — please update before
reporting an issue if you're not on the latest version from
[Releases](https://github.com/FOSScanner/fosscanner-app/releases/latest).

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, use [GitHub's private vulnerability
reporting](https://github.com/FOSScanner/fosscanner-app/security/advisories/new)
for this repository (Security tab → "Report a vulnerability"). This opens
a private discussion with maintainers before anything becomes public.

Given the app's design — all image processing and PDF generation happens
on-device, and it makes no network requests of its own (see the README's
"Privacy" section) — the most relevant classes of report are below. Automatic
native drafts use the app-private, OS-managed application cache: they survive
normal process death and restarts, but can be purged under storage pressure and
are excluded from Android OS backup.

- Anything that would let a malicious document/image trigger memory
  corruption or a crash via the native OpenCV pipeline
  (`document_processor_native.dart`)
- Anything that would expose app-private automatic draft files, retain them
  after an explicit clear, or cause photos/generated PDFs to be persisted or
  leaked outside the retention behavior documented in the README

Dependency vulnerabilities are also welcome as reports, though Dependabot
already opens PRs for those automatically where a fix is available.
