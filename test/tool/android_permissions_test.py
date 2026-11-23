import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tool.check_android_permissions import (
    APPLICATION_ID,
    CAMERA,
    RECEIVER,
    main,
    permission_errors,
)


class AndroidPermissionsTest(unittest.TestCase):
    def manifest(self, extra="", camera=True):
        camera_xml = f'<uses-permission android:name="{CAMERA}" />' if camera else ""
        return ET.fromstring(
            f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
            f'xmlns:tools="http://schemas.android.com/tools" package="{APPLICATION_ID}">'
            f"{camera_xml}{extra}</manifest>"
        )

    def receiver(self, protection="signature"):
        return (
            f'<permission android:name="{RECEIVER}" '
            f'android:protectionLevel="{protection}" />'
            f'<uses-permission android:name="{RECEIVER}" />'
        )

    def test_camera_only_is_allowed(self):
        self.assertEqual(permission_errors(self.manifest()), [])

    def test_androidx_signature_permission_is_allowed(self):
        for protection in ["signature", "2", "0x2", "0x00000002"]:
            with self.subTest(protection=protection):
                self.assertEqual(
                    permission_errors(self.manifest(self.receiver(protection))), []
                )

    def test_plugin_permissions_are_rejected_even_with_legacy_sdk_limits(self):
        for name in [
            "RECORD_AUDIO", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE",
            "ACCESS_NETWORK_STATE", "INTERNET", "READ_MEDIA_IMAGES",
        ]:
            with self.subTest(name=name):
                errors = permission_errors(self.manifest(
                    f'<uses-permission android:name="android.permission.{name}" '
                    'android:maxSdkVersion="28" />'
                ))
                self.assertTrue(any(name in error for error in errors))

    def test_sdk_specific_permission_tags_cannot_bypass_the_allowlist(self):
        for tag in ["uses-permission-sdk-23", "uses-permission-sdk-m", "uses-permission-new"]:
            with self.subTest(tag=tag):
                self.assertTrue(permission_errors(self.manifest(
                    f'<{tag} android:name="android.permission.RECORD_AUDIO" />'
                )))

    def test_unknown_custom_permissions_are_rejected(self):
        self.assertTrue(permission_errors(self.manifest(
            '<permission android:name="com.example.extra" android:protectionLevel="signature" />'
        )))
        self.assertTrue(permission_errors(self.manifest(
            '<uses-permission android:name="com.example.extra" />'
        )))

    def test_receiver_cannot_be_downgraded_or_given_extra_flags(self):
        for protection in ["normal", "dangerous", "signatureOrSystem", "signature|privileged", "0x12", ""]:
            with self.subTest(protection=protection):
                self.assertTrue(permission_errors(self.manifest(self.receiver(protection))))

    def test_requested_receiver_must_have_a_declaration(self):
        self.assertTrue(permission_errors(self.manifest(
            f'<uses-permission android:name="{RECEIVER}" />'
        )))

    def test_duplicate_declarations_are_rejected(self):
        self.assertTrue(permission_errors(self.manifest(self.receiver() * 2)))

    def test_permission_trees_and_groups_are_rejected(self):
        for tag in ["permission-tree", "permission-group"]:
            with self.subTest(tag=tag):
                self.assertTrue(permission_errors(self.manifest(
                    f'<{tag} android:name="{RECEIVER}" />'
                )))

    def test_missing_permission_names_are_rejected(self):
        self.assertTrue(permission_errors(self.manifest('<uses-permission />')))
        self.assertTrue(permission_errors(self.manifest('<permission />')))

    def test_missing_camera_is_rejected(self):
        self.assertTrue(permission_errors(self.manifest(camera=False)))

    def test_camera_cannot_be_restricted_to_a_subset_of_supported_apis(self):
        for camera in [
            f'<uses-permission android:name="{CAMERA}" android:maxSdkVersion="28" />',
            f'<uses-permission-sdk-23 android:name="{CAMERA}" />',
        ]:
            with self.subTest(camera=camera):
                self.assertTrue(permission_errors(self.manifest(camera, camera=False)))

    def test_wrong_application_and_non_manifest_input_are_rejected(self):
        root = self.manifest()
        root.set("package", "com.other.app")
        self.assertTrue(permission_errors(root))
        self.assertTrue(permission_errors(ET.fromstring("<application />")))

    def test_source_removal_directives_are_not_treated_as_processed_permissions(self):
        self.assertTrue(permission_errors(self.manifest(
            '<uses-permission android:name="android.permission.RECORD_AUDIO" tools:node="remove" />'
        )))

    def test_cli_handles_valid_invalid_missing_and_malformed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "AndroidManifest.xml"
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main([str(path)]), 1)
                path.write_text("<manifest>")
                self.assertEqual(main([str(path)]), 1)
                path.write_bytes(ET.tostring(self.manifest()))
                self.assertEqual(main([str(path)]), 0)
                path.write_bytes(ET.tostring(self.manifest('<uses-permission android:name="android.permission.INTERNET" />')))
                self.assertEqual(main([str(path)]), 1)


if __name__ == "__main__":
    unittest.main()
