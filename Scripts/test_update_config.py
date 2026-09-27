import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

from update_config import validate


class UpdateReleaseTests(unittest.TestCase):
    def info(self):
        return {
            "CFBundleIdentifier": "local.nami.studio",
            "CFBundleVersion": "2", "CFBundleShortVersionString": "0.1.1",
            "SUFeedURL": "https://github.com/OlegGulevskyy/nami/releases/latest/download/appcast.xml",
            "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode(),
        }

    def test_missing_or_unsafe_configuration_cannot_be_distributed(self):
        validate(self.info())
        for field, value in [
            ("SUFeedURL", ""), ("SUFeedURL", "http://example.com/feed.xml"),
            ("SUFeedURL", "https://user:pass@example.com/feed.xml"),
            ("SUPublicEDKey", ""), ("SUPublicEDKey", "not base64"),
            ("CFBundleVersion", "0"), ("CFBundleVersion", "-1"),
            ("CFBundleShortVersionString", "../version"),
            ("CFBundleIdentifier", "another.app"),
        ]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate(self.info() | {field: value})

    def test_stamp_updates_only_staged_bundle_and_rejects_bad_input_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Nami.app"
            plist = app / "Contents/Info.plist"
            plist.parent.mkdir(parents=True)
            plist.write_bytes(plistlib.dumps(self.info()))
            command = [sys.executable, str(Path(__file__).with_name("update_config.py")), str(app), "--stamp", "--require-updates"]
            env = os.environ | {"NAMI_VERSION": "0.2.0", "NAMI_BUILD_NUMBER": "3"}
            subprocess.run(command, env=env, check=True, capture_output=True)
            info = plistlib.loads(plist.read_bytes())
            self.assertEqual(info["CFBundleVersion"], "3")
            self.assertEqual(info["CFBundleShortVersionString"], "0.2.0")
            before = plist.read_bytes()
            result = subprocess.run(command, env=env | {"NAMI_BUILD_NUMBER": "invalid"}, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(plist.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
