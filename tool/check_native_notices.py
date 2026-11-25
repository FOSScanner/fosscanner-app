"""Verify the native notice texts shipped in an APK, not just the source tree."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
SEPARATOR = "\n" + "-" * 80 + "\n"


def notice_errors(apk, source_root=ROOT, engine_license=None):
    folder = source_root / "assets/licenses"
    provenance = json.loads((folder / "provenance.json").read_text())
    errors = []
    with ZipFile(apk) as archive:
        for name, expected in provenance["outputs"].items():
            asset = "assets/flutter_assets/assets/licenses/" + name
            source = (folder / name).read_bytes()
            if hashlib.sha256(source).hexdigest() != expected:
                errors.append(f"{name}: source differs from reviewed provenance")
            if asset not in archive.namelist():
                errors.append(f"{name}: missing packaged notice")
            elif archive.read(asset) != source:
                errors.append(f"{name}: packaged notice differs from source")
        if engine_license is not None:
            generated = gzip.decompress(archive.read("assets/flutter_assets/NOTICES.Z")).decode("utf-8")
            # Flutter reorders and merges package headings. Compare license
            # bodies, preserving their exact text, rather than the whole file.
            for index, block in enumerate(engine_license.read_text().split(SEPARATOR)):
                body = block.split("\n\n", 1)[-1]
                if body not in generated:
                    errors.append(f"Flutter engine license body {index} is missing")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--engine-license", type=Path)
    args = parser.parse_args()
    errors = notice_errors(args.apk, engine_license=args.engine_license)
    if errors:
        parser.exit(1, "\n".join(errors) + "\n")
    print("Packaged native notices match the reviewed source texts")
    if args.engine_license is not None:
        print("All pinned Flutter engine license bodies are present")


if __name__ == "__main__":
    main()
