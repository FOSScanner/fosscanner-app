"""Fail closed on permissions in the processed Android release manifest."""

import argparse
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
TOOLS = "{http://schemas.android.com/tools}"
APPLICATION_ID = "com.fosscanner.app"
CAMERA = "android.permission.CAMERA"
RECEIVER = f"{APPLICATION_ID}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
ALLOWED = {CAMERA, RECEIVER}
PERMISSION_TAGS = {"uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m"}


def is_signature_only(value):
    if value == "signature":
        return True
    try:
        return int(value, 0) == 2
    except (TypeError, ValueError):
        return False


def permission_errors(root):
    errors = []
    if root.tag != "manifest" or root.get("package") != APPLICATION_ID:
        errors.append(f"Expected the processed release manifest for {APPLICATION_ID}")
    requested = set()
    declarations = []
    for element in root:
        if any(key.startswith(TOOLS) for key in element.attrib):
            errors.append("Unprocessed manifest-merger directives are not allowed")
        if element.tag.startswith("uses-permission"):
            if element.tag not in PERMISSION_TAGS:
                errors.append(f"Unknown permission tag: {element.tag}")
            name = element.get(f"{ANDROID}name")
            requested.add(name)
            if name not in ALLOWED:
                errors.append(f"Unexpected requested permission: {name!r}")
            if name == CAMERA and (
                element.tag != "uses-permission"
                or element.get(f"{ANDROID}maxSdkVersion") is not None
            ):
                errors.append("CAMERA must remain available on every supported API")
        elif element.tag in {"permission", "permission-tree", "permission-group"}:
            name = element.get(f"{ANDROID}name")
            declarations.append(name)
            if element.tag != "permission" or name != RECEIVER:
                errors.append(f"Unexpected permission declaration: {name!r}")
            elif not is_signature_only(element.get(f"{ANDROID}protectionLevel")):
                errors.append("The app's receiver permission must be signature-only")
    if CAMERA not in requested:
        errors.append("Required CAMERA permission is missing")
    if RECEIVER in requested and RECEIVER not in declarations:
        errors.append("Requested receiver permission has no signature declaration")
    if len(declarations) != len(set(declarations)):
        errors.append("Duplicate permission declarations are not allowed")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="processed release AndroidManifest.xml")
    args = parser.parse_args(argv)
    try:
        root = ET.parse(args.manifest).getroot()
    except (OSError, ET.ParseError) as error:
        print(f"Cannot inspect release manifest: {error}", file=sys.stderr)
        return 1
    errors = permission_errors(root)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Release permission allowlist passed (CAMERA and signature-only receiver)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
