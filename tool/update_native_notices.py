"""Regenerate bundled native notices from the pinned, local build inputs."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "assets/licenses"
COMMENT = re.compile(r"/\*.*?\*/|(?://[^\n]*(?:\n|$))+", re.DOTALL)
NOTICE = re.compile(r"copyright|SPDX-License-Identifier|redistribution and use|permission is hereby granted|public domain", re.IGNORECASE)
PINS = {
    "opencv": "fe38fc608f6acb8b68953438a62305d8318f4fcd",
    "kleidicv": "1e8fe7008c2292657b9689d70ea5d30db0e57767",
    "libyuv_notice_source": "03f119c01450d3c42f4902d66b77d18f7487c9a0",
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def source_comments(root, paths):
    """Keep verbatim notice-bearing comments, following bundled quoted includes."""
    seen = set()
    pending = list(paths)
    result = {}
    hashes = {}
    while pending:
        path = pending.pop().resolve()
        if path in seen:
            continue
        seen.add(path)
        relative = path.relative_to(root.resolve()).as_posix()
        raw = path.read_bytes()
        text = raw.decode("utf-8")
        hashes[relative] = sha256(raw)
        for match in COMMENT.finditer(text):
            comment = match.group().strip()
            if NOTICE.search(comment):
                result.setdefault(comment, []).append(relative)
        for include in re.findall(r'^\s*#\s*include\s+"([^"]+)"', text, re.MULTILINE):
            # This also resolves ZXing's forwarding files into zint/backend.
            target = (path.parent / include).resolve()
            if target.is_relative_to(root.resolve()) and target.is_file():
                pending.append(target)
    return [
        "Sources: " + ", ".join(sorted(paths)) + "\n" + comment
        for comment, paths in sorted(result.items(), key=lambda item: min(item[1]))
    ], hashes


def generate(args):
    for name, root in [("opencv", args.opencv), ("kleidicv", args.kleidicv)]:
        revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        dirty = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True)
        if revision != PINS[name] or dirty:
            raise ValueError(f"{name}: use a clean checkout at {PINS[name]}")
    sections = {}
    inputs = {}

    def file(label, root, path):
        raw = path.read_bytes()
        inputs[f"{label}/{path.relative_to(root).as_posix()}"] = sha256(raw)
        return raw.decode("utf-8").strip()

    zxing = args.zxing
    paths = [p for p in (zxing / "src/zxing/core/src").rglob("*")
             if p.suffix in {".c", ".cpp", ".h", ".hpp"}]
    if not paths or not (zxing / "src/zxing/zint/backend/library.c").is_file():
        raise ValueError("Expected the pinned flutter_zxing native sources")
    comments, hashes = source_comments(zxing, paths)
    inputs.update({f"flutter_zxing/{p}": h for p, h in hashes.items()})
    sections["BARCODE_NOTICES.txt"] = [
        "ZXing 3.1.1 and bundled Zint (flutter_zxing 3.1.1)\n"
        "This notice set conservatively includes native core headers and sources,\n"
        "including optional core code; it excludes Zint frontends and test programs.",
        "Apache-2.0 license text (also used by ZXing):\n" + file("opencv", args.opencv, args.opencv / "LICENSE"),
        *comments,
    ]
    commands = json.loads(args.opencv_compile_commands.read_text())
    modules = sorted({match.group(1) for command in commands
                      if (match := re.search(r"/cv/modules/([^/]+)/", command["file"]))})
    if not modules:
        raise ValueError("No OpenCV modules found in the Android compilation database")
    cv_paths = [p for module in modules for folder in ["src", "include"]
                for p in (args.opencv / "modules" / module / folder).rglob("*")
                if p.suffix in {".cpp", ".c", ".h", ".hpp"}]
    comments, hashes = source_comments(args.opencv, cv_paths)
    inputs.update({f"opencv/{p}": h for p, h in hashes.items()})
    sections["OPENCV_NOTICES.txt"] = [
        "OpenCV 4.13.0 and dependencies: Android CMake-installed notice set\n"
        "Source/header notice superset for compiled modules: " + ", ".join(modules),
        file("opencv", args.opencv, args.opencv / "LICENSE"),
        *[p.name + "\n" + file("opencv-installed", args.opencv_licenses, p)
          for p in sorted(args.opencv_licenses.iterdir()) if p.is_file()],
        *comments,
    ]
    kleidi_paths = [p for folder in ["kleidicv", "kleidicv_thread", "include", "src"]
                    for p in (args.kleidicv / folder).rglob("*")
                    if p.suffix in {".cpp", ".c", ".h", ".hpp", ".S"}]
    if not kleidi_paths or not (args.opencv_licenses / "libpng-LICENSE").is_file():
        raise ValueError("Expected KleidiCV sources and the Android-installed license set")
    comments, hashes = source_comments(args.kleidicv, kleidi_paths)
    inputs.update({f"kleidicv/{p}": h for p, h in hashes.items()})
    sections["KLEIDICV_NOTICES.txt"] = [
        "KleidiCV 0.7.0 (Arm)\nSPDX-License-Identifier: Apache-2.0",
        file("kleidicv", args.kleidicv, args.kleidicv / "LICENSES/Apache-2.0.txt"),
        *comments,
    ]
    sections["CAMERAX_NOTICES.txt"] = [
        "AndroidX CameraX camera-core 1.6.2 (Android Open Source Project), including libyuv\n"
        "The libyuv notice source revision is documented in README.md; it is not\n"
        "a claim to identify the exact libyuv commit in the Maven binary.",
        file("camera-core-sources", args.notice_inputs, args.notice_inputs / "camera-LICENSE"),
        *["libyuv " + name + "\n" + file("libyuv", args.notice_inputs, args.notice_inputs / ("libyuv-" + name))
          for name in ["LICENSE", "PATENTS", "AUTHORS"]],
    ]
    OUTPUT.mkdir(parents=True, exist_ok=True)
    outputs = {}
    for name, paragraphs in sections.items():
        data = ("\n\n" + "=" * 72 + "\n\n").join(paragraphs) + "\n"
        (OUTPUT / name).write_text(data)
        outputs[name] = sha256(data.encode())
    provenance = {
        "pubspec_lock_sha256": sha256((ROOT / "pubspec.lock").read_bytes()),
        "pins": PINS,
        "versions": {"flutter_zxing": "3.1.1", "opencv": "4.13.0", "kleidicv": "0.7.0", "camera-core": "1.6.2"},
        "inputs": dict(sorted(inputs.items())), "outputs": outputs,
    }
    (OUTPUT / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ["zxing", "opencv", "opencv-licenses", "opencv-compile-commands", "kleidicv", "notice-inputs"]:
        parser.add_argument("--" + option, type=Path, required=True)
    generate(parser.parse_args())


if __name__ == "__main__":
    main()
