# Contributing to FOSScanner

Thanks for considering a contribution. This is a small, privacy-first FOSS
project — issues and PRs of any size are welcome.

## Development setup

See the README's "Getting started" section for running the app. Skim the
code comments for the reasoning behind a few non-obvious decisions before
making non-trivial changes.

```bash
flutter pub get
flutter analyze
flutter test
```

Docker is also available if you don't want the Flutter/Android SDKs
installed locally — see the README's "Running with Docker" section.

## Commit messages: Conventional Commits

This repo's versioning and `CHANGELOG.md` are generated automatically by
[Release Please](https://github.com/googleapis/release-please) from commit
messages on `main`, following [Conventional
Commits](https://www.conventionalcommits.org/). Please prefix commits (or
at minimum, squash-merged PR titles) accordingly:

| Prefix | Effect |
|---|---|
| `fix: ...` | Patch release (bug fixes) |
| `feat: ...` | Minor release (new features) |
| `feat!: ...` or a `BREAKING CHANGE:` footer | Major release |
| `docs:`, `chore:`, `refactor:`, `test:`, `ci:` | No version bump, but recorded |

A commit that doesn't follow this format still merges fine — it just won't
show up correctly in the next automated changelog entry.

Commits should be attributed to their actual human author. Please don't
add `Co-Authored-By` trailers for AI coding assistants.

## Pull requests

- Keep PRs focused — one logical change per PR is easier to review and
  keeps `git bisect` useful.
- CI (`flutter analyze` + `flutter test`) must pass before merge.
- For anything touching `document_processor_native.dart` or the OpenCV
  bindings, please test on a real device or emulator — `flutter_test`'s
  fake-time test binding doesn't reliably exercise the native image
  pipeline.

## Reporting bugs / requesting features

Use the issue templates — they ask for the platform (Android/web) and
Flutter version, which is usually the first thing needed to reproduce
anything in this codebase given how much of it is native-only.

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability privately
instead of opening a public issue.
