import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import github_release as release


def feed(version="0.2.0", build=3, length=3):
    return f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
    <enclosure url="https://github.com/OlegGulevskyy/nami/releases/download/v{version}/Nami-{version}-macOS-arm64.zip"
      length="{length}" sparkle:edSignature="test-signature" /></item></channel></rss>'''.encode()


class ReleaseTests(unittest.TestCase):
    def test_only_stable_numeric_tags_are_accepted(self):
        self.assertEqual(release.release_version("v1.2.3"), "1.2.3")
        for tag in ["1.2.3", "v1.2", "v1.2.3-beta", "v01.2.3", "v1.2.3\n", "v$(id)", "v../../secret"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.release_version(tag)

    def test_older_versions_and_reused_builds_never_replace_published_updates(self):
        current = release.feed_info(feed())
        release.require_newer("0.3.0", 4, current)
        for version, build in [("0.1.0", 9), ("0.2.0", 9), ("0.3.0", 3), ("0.3.0", 2)]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                release.require_newer(version, build, current)

    def test_metadata_derives_version_build_and_completed_retry_is_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {"GITHUB_ENV": str(Path(directory) / "env"), "GITHUB_OUTPUT": str(Path(directory) / "output"), "GITHUB_RUN_NUMBER": "1"}
            with patch.dict(os.environ, env), patch.object(release, "api", return_value={"draft": False, "prerelease": False, "tag_name": "v0.2.0"}), patch.object(release, "current_feed", return_value=({"version": "0.1.0", "build": 100}, "sha")):
                release.metadata("v0.2.0")
            self.assertIn("NAMI_VERSION=0.2.0\nNAMI_BUILD_NUMBER=101", Path(env["GITHUB_ENV"]).read_text())
            self.assertIn("already_published=false", Path(env["GITHUB_OUTPUT"]).read_text())
            with patch.dict(os.environ, env), patch.object(release, "api", return_value={"draft": False, "prerelease": False, "tag_name": "v0.2.0"}), patch.object(release, "current_feed", return_value=(release.feed_info(feed()), "sha")):
                release.metadata("v0.2.0")
            self.assertTrue(Path(env["GITHUB_OUTPUT"]).read_text().endswith("already_published=true\n"))

    def test_drafts_and_prereleases_are_rejected(self):
        for draft, prerelease in [(True, False), (False, True)]:
            with patch.object(release, "api", return_value={"draft": draft, "prerelease": prerelease, "tag_name": "v0.2.0"}), self.assertRaises(ValueError):
                release.metadata("v0.2.0")

    def test_failed_upload_keeps_previous_feed_and_success_promotes_last(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            try:
                os.chdir(directory)
                assets = Path(".build/updates/v0.2.0-3")
                assets.mkdir(parents=True)
                (assets / "appcast.xml").write_bytes(feed())
                (assets / "Nami-0.2.0-macOS-arm64.zip").write_bytes(b"zip")
                calls = []
                def failed_upload(command, **kwargs):
                    if command[:3] == ["gh", "release", "upload"]:
                        raise subprocess.CalledProcessError(1, command)
                with patch.dict(os.environ, {"NAMI_BUILD_NUMBER": "3"}), patch.object(release, "api", return_value={"draft": False, "prerelease": False}), patch.object(release, "current_feed", return_value=(None, None)), patch.object(release, "promote_feed") as promote:
                    with patch.object(release.subprocess, "run", side_effect=failed_upload), self.assertRaises(subprocess.CalledProcessError):
                        release.publish("v0.2.0")
                    promote.assert_not_called()
                    with patch.object(release.subprocess, "run", side_effect=lambda cmd, **kw: calls.append(cmd)), patch.object(release, "promote_feed", side_effect=lambda *args: calls.append("promote")):
                        release.publish("v0.2.0")
                    self.assertEqual(calls[-1], "promote")
                    self.assertEqual(calls[-2][:3], ["gh", "release", "upload"])
            finally:
                os.chdir(previous)

    def test_feed_updates_use_compare_and_swap(self):
        with patch.object(release, "api") as api:
            release.promote_feed(feed(), "old-blob-sha")
            self.assertEqual(api.call_args.args[1]["sha"], "old-blob-sha")
            self.assertEqual(api.call_args.args[1]["branch"], "updates")
            self.assertEqual(api.call_args.kwargs["method"], "PUT")


if __name__ == "__main__":
    unittest.main()
