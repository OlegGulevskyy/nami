#!/usr/bin/env python3
"""Validate update configuration and stamp an unsigned, staged app bundle."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import urlsplit


def validate(info):
    feed = info.get("SUFeedURL", "")
    url = urlsplit(feed)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or "$(" in feed):
        raise ValueError("Set an HTTPS NAMI_UPDATE_FEED_URL in Resources/Updates.xcconfig.")
    try:
        key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
    except (ValueError, TypeError):
        key = b""
    if len(key) != 32:
        raise ValueError("Set NAMI_UPDATE_PUBLIC_KEY in Resources/Updates.xcconfig to the Sparkle public key.")
    if not re.fullmatch(r"[1-9][0-9]*", str(info.get("CFBundleVersion", ""))):
        raise ValueError("NAMI_BUILD_NUMBER must be a positive, increasing integer.")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(info.get("CFBundleShortVersionString", ""))):
        raise ValueError("NAMI_VERSION must have the form 1.2.3.")
    if info.get("CFBundleIdentifier") != "local.nami.studio":
        raise ValueError("The update must keep Nami's bundle identifier.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--stamp", action="store_true", help="Apply version environment variables before signing")
    parser.add_argument("--require-updates", action="store_true")
    args = parser.parse_args()
    path = args.app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    if args.stamp:
        for env, field in [("NAMI_VERSION", "CFBundleShortVersionString"), ("NAMI_BUILD_NUMBER", "CFBundleVersion")]:
            if env in os.environ:
                pattern = r"[0-9]+\.[0-9]+\.[0-9]+" if env == "NAMI_VERSION" else r"[1-9][0-9]*"
                if not re.fullmatch(pattern, os.environ[env]):
                    raise ValueError(f"Invalid {env}: use a numeric version or positive integer build number.")
                info[field] = os.environ[env]
    if args.require_updates:
        validate(info)
    if args.stamp:
        path.write_bytes(plistlib.dumps(info))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
