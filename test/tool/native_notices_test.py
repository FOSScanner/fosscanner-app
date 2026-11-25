import gzip
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tool.update_native_notices import ROOT, source_comments
from tool.check_native_notices import notice_errors, SEPARATOR


class NativeNoticesTest(unittest.TestCase):
    def test_generated_notices_match_reviewed_hashes(self):
        folder = ROOT / "assets/licenses"
        provenance = json.loads((folder / "provenance.json").read_text())
        self.assertEqual(provenance["pubspec_lock_sha256"], hashlib.sha256(
            (ROOT / "pubspec.lock").read_bytes()).hexdigest(),
            "Dependency graph changed: review and regenerate native notices")
        self.assertEqual(set(provenance["outputs"]), {
            "BARCODE_NOTICES.txt", "OPENCV_NOTICES.txt",
            "KLEIDICV_NOTICES.txt", "CAMERAX_NOTICES.txt",
        })
        for name, expected in provenance["outputs"].items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((folder / name).read_bytes()).hexdigest(), expected)
                self.assertIn(f"assets/licenses/{name}", (ROOT / "pubspec.yaml").read_text())

    def test_included_notices_are_retained_without_copying_implementation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.c").write_text('/* Copyright A; BSD terms */\n#include "b.h"\nint a = 0;\n')
            (root / "b.h").write_text('// Copyright B\n// SPDX-License-Identifier: Apache-2.0\n#include "a.c"\n')
            notices, hashes = source_comments(root, [root / "a.c"])
            text = "\n".join(notices)
            self.assertIn('/* Copyright A; BSD terms */', text)
            self.assertIn('// Copyright B', text)
            self.assertNotIn('int a = 0', text)
            self.assertEqual(set(hashes), {"a.c", "b.h"})

    def test_apk_check_rejects_missing_changed_and_stale_notices(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            folder = root / "assets/licenses"
            folder.mkdir(parents=True)
            text = b"Reviewed BSD notice"
            (folder / "TEST.txt").write_bytes(text)
            (folder / "provenance.json").write_text(json.dumps({
                "outputs": {"TEST.txt": hashlib.sha256(text).hexdigest()},
            }))
            apk = root / "test.apk"
            asset = "assets/flutter_assets/assets/licenses/TEST.txt"
            for contents in [None, b"different", text]:
                with self.subTest(contents=contents):
                    with ZipFile(apk, "w") as archive:
                        if contents is not None:
                            archive.writestr(asset, contents)
                    self.assertEqual(bool(notice_errors(apk, root)), contents != text)
            (folder / "TEST.txt").write_bytes(b"unreviewed source")
            self.assertTrue(notice_errors(apk, root))

    def test_engine_license_bodies_survive_regrouping_but_not_omission(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            folder = root / "assets/licenses"
            folder.mkdir(parents=True)
            (folder / "provenance.json").write_text('{"outputs": {}}')
            engine = root / "engine-LICENSE"
            engine.write_text("A\n\nLicense A" + SEPARATOR + "B\n\nLicense B")
            apk = root / "test.apk"
            for notices, expected_errors in [
                ("New B\n\nLicense B" + SEPARATOR + "New A\n\nLicense A", False),
                ("B\n\nLicense B", True),
            ]:
                with ZipFile(apk, "w") as archive:
                    archive.writestr("assets/flutter_assets/NOTICES.Z", gzip.compress(notices.encode()))
                self.assertEqual(bool(notice_errors(apk, root, engine)), expected_errors)

    def test_quoted_includes_cannot_escape_the_source_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            root = parent / "src"
            root.mkdir()
            (parent / "outside.h").write_text('// Copyright outside\n')
            (root / "a.c").write_text('#include "../outside.h"\n')
            notices, hashes = source_comments(root, [root / "a.c"])
            self.assertEqual(notices, [])
            self.assertEqual(set(hashes), {"a.c"})


if __name__ == "__main__":
    unittest.main()
