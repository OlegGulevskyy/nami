#!/usr/bin/env python3
"""Publish assets first, then atomically advance the signed feed on updates."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

REPO = "OlegGulevskyy/nami"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def version_tuple(version):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Use a stable release tag like v0.1.1 (no prerelease suffix).")
    return tuple(map(int, version.split(".")))


def release_version(tag):
    if not tag.startswith("v"):
        raise ValueError("Release tags must start with v, for example v0.1.1.")
    version_tuple(tag[1:])
    return tag[1:]


def api(path, payload=None, *, method=None, missing_ok=False):
    command = ["gh", "api", f"repos/{REPO}/{path}", "--method", method or ("POST" if payload is not None else "GET")]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        if missing_ok and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(f"GitHub API failed for {path}: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def feed_info(data):
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The stable feed must contain exactly one release.")
    item = items[0]
    version = item.findtext(NS + "shortVersionString", "")
    version_tuple(version)
    build = item.findtext(NS + "version", "")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Invalid build number in update feed.")
    enclosure = item.find("enclosure")
    if enclosure is None or not enclosure.get(NS + "edSignature"):
        raise ValueError("Update feed is missing its signed archive.")
    return {"version": version, "build": int(build), "url": enclosure.get("url"),
            "signature": enclosure.get(NS + "edSignature"), "length": int(enclosure.get("length", "0"))}


def current_feed():
    entry = api("contents/appcast.xml?ref=updates", missing_ok=True)
    if entry is None:
        return None, None
    return feed_info(base64.b64decode(entry["content"])), entry["sha"]


def require_newer(version, build, current):
    if current and (version_tuple(version) <= version_tuple(current["version"]) or build <= current["build"]):
        raise ValueError("This release would reuse or downgrade the published version/build. Publish a newer tag.")


def metadata(tag):
    version = release_version(tag)
    release = api(f"releases/tags/{tag}")
    if release["draft"] or release["prerelease"] or release["tag_name"] != tag:
        raise ValueError("Only an existing, published stable release can be built.")
    current, _ = current_feed()
    # Rerunning a completed release is a no-op; never replace its signed ZIP.
    already_published = bool(current and current["version"] == version)
    build = max(int(os.environ["GITHUB_RUN_NUMBER"]) + 1, (current["build"] + 1) if current else 2)
    if not already_published:
        require_newer(version, build, current)
    with open(os.environ["GITHUB_ENV"], "a") as env:
        env.write(f"NAMI_VERSION={version}\nNAMI_BUILD_NUMBER={build}\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"already_published={str(already_published).lower()}\n")
    print(f"{'Already published' if already_published else 'Preparing'} {tag}, build {build}")


def promote_feed(data, previous_sha):
    content = base64.b64encode(data).decode()
    if previous_sha:
        # Contents API uses the previous blob SHA as an optimistic concurrency check.
        api("contents/appcast.xml", {"message": "Publish signed Nami update feed", "branch": "updates",
                                     "sha": previous_sha, "content": content}, method="PUT")
    else:
        # First publication creates an orphan branch containing only the signed feed.
        # No default-branch source files or workflow files are copied into it.
        blob = api("git/blobs", {"content": content, "encoding": "base64"})
        tree = api("git/trees", {"tree": [{"path": "appcast.xml", "mode": "100644", "type": "blob", "sha": blob["sha"]}]})
        commit = api("git/commits", {"message": "Publish signed Nami update feed", "tree": tree["sha"], "parents": []})
        api("git/refs", {"ref": "refs/heads/updates", "sha": commit["sha"]})


def publish(tag):
    version = release_version(tag)
    build = int(os.environ["NAMI_BUILD_NUMBER"])
    directory = Path(f".build/updates/{tag}-{build}")
    feed_path = directory / "appcast.xml"
    archive = directory / f"Nami-{version}-macOS-arm64.zip"
    data = feed_path.read_bytes()
    item = feed_info(data)
    if (item["version"] != version or item["build"] != build or
            item["url"] != f"https://github.com/{REPO}/releases/download/{tag}/{archive.name}" or
            item["length"] != archive.stat().st_size):
        raise ValueError("Prepared update does not match this release.")
    signer = ".build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    key_file = os.environ.get("NAMI_SPARKLE_KEY_FILE")
    key_args = ["--ed-key-file", key_file] if key_file else ["--account", "local.nami.studio"]
    subprocess.run([signer, *key_args, "--verify", str(feed_path)], check=True)
    subprocess.run([signer, *key_args, "--verify", str(archive), item["signature"]], check=True)
    current, previous_sha = current_feed()
    require_newer(version, build, current)
    release = api(f"releases/tags/{tag}")
    if release["draft"] or release["prerelease"]:
        raise ValueError("The release is no longer published/stable.")
    # A retry may replace assets from a failed build, but only while this version
    # has never been promoted to the stable feed. Published updates are immutable.
    subprocess.run(["gh", "release", "upload", tag, str(archive), str(feed_path),
                    "--repo", REPO, "--clobber"], check=True)
    # Re-read immediately before promotion; refuse stale builds or competing edits.
    current, latest_sha = current_feed()
    require_newer(version, build, current)
    if latest_sha != previous_sha:
        raise ValueError("The stable feed changed during upload; rerun this workflow.")
    promote_feed(data, previous_sha)
    print(f"Published {tag}: release assets uploaded and stable update feed advanced.")


if __name__ == "__main__":
    try:
        if os.environ.get("GITHUB_REPOSITORY") != REPO:
            raise ValueError("Release automation is restricted to the Nami repository.")
        tag = os.environ["NAMI_RELEASE_TAG"]
        {"metadata": metadata, "publish": publish}[sys.argv[1]](tag)
    except (ValueError, RuntimeError, KeyError, OSError, ET.ParseError) as error:
        raise SystemExit(str(error))
