from pathlib import Path
import re
import struct
import unittest


ROOT = Path(__file__).resolve().parents[2]
METADATA = ROOT / "fastlane/metadata/android/en-US"


class StoreMetadataTest(unittest.TestCase):
    def test_english_listing_is_nonempty_and_within_store_limits(self):
        for name, limit in [
            ("title.txt", 30),
            ("short_description.txt", 80),
            ("full_description.txt", 4000),
        ]:
            with self.subTest(name=name):
                raw = (METADATA / name).read_bytes()
                text = raw.decode("utf-8").strip()
                self.assertTrue(text)
                self.assertLessEqual(len(text), limit)
                self.assertNotIn(b"\r", raw)

    def test_release_notes_match_the_proposed_fdroid_candidate(self):
        # The recipe targets a public tag, not the development branch's version.
        recipe = (ROOT / "contrib/fdroiddata/metadata/com.fosscanner.app.yml").read_text()
        match = re.search(r"^CurrentVersionCode: (\d+)$", recipe, re.MULTILINE)
        self.assertIsNotNone(match)
        packaged_code = int(match.group(1))
        notes = (METADATA / f"changelogs/{packaged_code}.txt").read_text().strip()
        self.assertTrue(notes)
        self.assertLessEqual(len(notes), 500)

    def test_phone_images_match_the_documented_synthetic_renders(self):
        names = ["ui-home-pages", "ui-adjust-appearance", "ui-export-options"]
        for number, name in enumerate(names, 1):
            with self.subTest(name=name):
                image = (METADATA / f"images/phoneScreenshots/{number}.png").read_bytes()
                self.assertEqual(image[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(struct.unpack(">II", image[16:24]), (780, 1688))
                self.assertEqual(image, (ROOT / f"docs/screenshots/{name}.png").read_bytes())

    def test_icon_is_a_512_pixel_png(self):
        icon = (METADATA / "images/icon.png").read_bytes()
        self.assertEqual(icon[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack(">II", icon[16:24]), (512, 512))


if __name__ == "__main__":
    unittest.main()
