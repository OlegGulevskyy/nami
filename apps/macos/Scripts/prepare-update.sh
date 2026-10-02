#!/bin/zsh
# Prepare reviewable release assets locally. This script never publishes.
set -euo pipefail
NAMI_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$NAMI_PROJECT_DIR"
if (( $# > 1 )) || [[ "${1:-}" == "--help" ]]; then
  print 'Usage: ./Scripts/prepare-update.sh [path/to/release-notes.md]'
  print 'Requires .build/distribution/Nami.app from distribute.sh and the Nami Sparkle key in Keychain.'
  print 'Writes versioned ZIP, signed appcast.xml, and release notes under .build/updates/.'
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 1
fi
NAMI_NOTES=""
if (( $# )); then
  NAMI_NOTES="${1:A}"
  [[ -s "$NAMI_NOTES" ]] || { print -u2 'Release notes must exist and be nonempty.'; exit 1; }
fi
NAMI_APP="$NAMI_PROJECT_DIR/.build/distribution/Nami.app"
NAMI_SPARKLE_BIN="$NAMI_PROJECT_DIR/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$NAMI_SPARKLE_BIN/generate_appcast" ]] || { print -u2 'Build Nami to resolve Sparkle first.'; exit 1; }
python3 Scripts/update_config.py "$NAMI_APP" --require-updates
codesign --verify --deep --strict "$NAMI_APP"
xcrun stapler validate "$NAMI_APP"
spctl --assess --type execute "$NAMI_APP"
NAMI_KEY_ACCOUNT=local.nami.studio
NAMI_SPARKLE_KEY_ARGS=(--account "$NAMI_KEY_ACCOUNT")
if [[ -n "${NAMI_SPARKLE_KEY_FILE:-}" ]]; then
  NAMI_SPARKLE_KEY_ARGS=(--ed-key-file "$NAMI_SPARKLE_KEY_FILE")
  NAMI_PUBLIC_KEY="$(swift Scripts/sparkle-public-key.swift "$NAMI_SPARKLE_KEY_FILE")"
else
  NAMI_PUBLIC_KEY="$("$NAMI_SPARKLE_BIN/generate_keys" --account "$NAMI_KEY_ACCOUNT" -p)"
fi
NAMI_EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$NAMI_APP/Contents/Info.plist")"
[[ "$NAMI_PUBLIC_KEY" == "$NAMI_EMBEDDED_KEY" ]] || { print -u2 'Sparkle Keychain key does not match the public key in this app.'; exit 1; }
NAMI_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NAMI_APP/Contents/Info.plist")"
NAMI_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NAMI_APP/Contents/Info.plist")"
NAMI_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$NAMI_APP/Contents/Info.plist")"
NAMI_REPO=OlegGulevskyy/nami
[[ "$NAMI_FEED" == "https://raw.githubusercontent.com/$NAMI_REPO/updates/appcast.xml" ]] || {
  print -u2 'Feed does not match the GitHub release repository in this script.'; exit 1
}
# Refuse downgrade/reused build numbers, including when a release was prepared earlier.
python3 - "$NAMI_FEED" "$NAMI_BUILD" "$NAMI_VERSION" <<'PY'
import sys, urllib.error, urllib.request, xml.etree.ElementTree as ET
try:
    with urllib.request.urlopen(sys.argv[1], timeout=30) as response:
        feed = ET.fromstring(response.read(1024 * 1024))
except urllib.error.HTTPError as error:
    if error.code != 404:
        raise
else:
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    versions = [item.text for item in feed.iter(ns + 'version')]
    versions += [item.get(ns + 'version') for item in feed.iter('enclosure') if item.get(ns + 'version')]
    if not versions or any(not version.isdecimal() for version in versions):
        raise SystemExit('Cannot establish the currently published build number from the feed.')
    if int(sys.argv[2]) <= max(map(int, versions)):
        raise SystemExit('NAMI_BUILD_NUMBER must exceed every build in the published feed.')
    for version in feed.iter(ns + 'shortVersionString'):
        if tuple(map(int, sys.argv[3].split('.'))) <= tuple(map(int, version.text.split('.'))):
            raise SystemExit('NAMI_VERSION must exceed the version in the published feed.')
PY
NAMI_TAG="v$NAMI_VERSION"
NAMI_OUTPUT="$NAMI_PROJECT_DIR/.build/updates/$NAMI_TAG-$NAMI_BUILD"
[[ ! -e "$NAMI_OUTPUT" ]] || { print -u2 "Already prepared: $NAMI_OUTPUT. Choose a new version/build."; exit 1; }
mkdir -p "$NAMI_PROJECT_DIR/.build/updates"
NAMI_STAGE="$(mktemp -d "$NAMI_PROJECT_DIR/.build/updates/.prepare.XXXXXX")"
trap 'rm -rf "$NAMI_STAGE"' EXIT ZERR
NAMI_ARCHIVE="Nami-$NAMI_VERSION-macOS-arm64"
ditto -c -k --keepParent "$NAMI_APP" "$NAMI_STAGE/$NAMI_ARCHIVE.zip"
if [[ -n "$NAMI_NOTES" ]]; then
  cp "$NAMI_NOTES" "$NAMI_STAGE/$NAMI_ARCHIVE.md"
fi
"$NAMI_SPARKLE_BIN/generate_appcast" "${NAMI_SPARKLE_KEY_ARGS[@]}" \
  --download-url-prefix "https://github.com/$NAMI_REPO/releases/download/$NAMI_TAG/" \
  --embed-release-notes --maximum-deltas 0 -o "$NAMI_STAGE/appcast.xml" "$NAMI_STAGE"
"$NAMI_SPARKLE_BIN/sign_update" "${NAMI_SPARKLE_KEY_ARGS[@]}" --verify "$NAMI_STAGE/appcast.xml"
python3 - "$NAMI_STAGE/appcast.xml" "$NAMI_BUILD" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = root.findall('./channel/item')
if len(items) != 1 or items[0].findtext(ns + 'version') != sys.argv[2]:
    raise SystemExit('Generated appcast does not match the prepared build.')
enclosure = items[0].find('enclosure')
if enclosure is None or not enclosure.get(ns + 'edSignature'):
    raise SystemExit('Generated appcast has no signed update archive.')
PY
mv "$NAMI_STAGE" "$NAMI_OUTPUT"
print "Prepared for review: $NAMI_OUTPUT"
print "Release tag: $NAMI_TAG (build $NAMI_BUILD)"
print 'Nothing has been uploaded or published. Review the app, release notes, and appcast before publishing.'
