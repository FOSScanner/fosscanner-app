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
"Privacy" section) — the most relevant classes of report are:

- Anything that would let a malicious document/image trigger memory
  corruption or a crash via the native OpenCV pipeline
  (`document_processor_native.dart`)
- Anything that would cause photos or generated PDFs to be persisted or
  leaked when they shouldn't be (see the README's privacy guarantees)

Dependency vulnerabilities are also welcome as reports, though Dependabot
already opens PRs for those automatically where a fix is available.
