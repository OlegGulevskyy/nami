#!/bin/zsh
set -euo pipefail
NAMI_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$NAMI_PROJECT_DIR"
source Scripts/signing.sh
NAMI_BUILD_ARGUMENTS=(--distribution)
if [[ "${1:-}" == "--package-only" && $# == 1 ]]; then
  NAMI_BUILD_ARGUMENTS+=(--package-only)
elif (( $# )); then
  print 'Usage: NAMI_NOTARY_PROFILE=nami-notary ./Scripts/distribute.sh [--package-only]'
  print 'Builds a Developer ID signed app, submits it to Apple, staples the ticket, and creates a sharing ZIP.'
  [[ "$1" == "--help" ]] && exit 0
  exit 1
fi
nami_resolve_identity
export NAMI_SIGNING_IDENTITY
NAMI_NOTARY_PROFILE="${NAMI_NOTARY_PROFILE:-nami-notary}"
# Fail before building/uploading if credentials have not been configured.
xcrun notarytool history --keychain-profile "$NAMI_NOTARY_PROFILE" > /dev/null
./Scripts/app.sh "${NAMI_BUILD_ARGUMENTS[@]}"
NAMI_DIST_DIR="$NAMI_PROJECT_DIR/.build/distribution"
NAMI_UPLOAD_DIR="$(mktemp -d "$NAMI_DIST_DIR/.notarize.XXXXXX")"
trap 'rm -rf "$NAMI_UPLOAD_DIR"' EXIT ZERR
ditto -c -k --keepParent "$NAMI_DIST_DIR/Nami.app" "$NAMI_UPLOAD_DIR/Nami.zip"
NAMI_NOTARY_RESULT="$NAMI_DIST_DIR/notarization.json"
if ! xcrun notarytool submit "$NAMI_UPLOAD_DIR/Nami.zip" \
  --keychain-profile "$NAMI_NOTARY_PROFILE" --wait --output-format json > "$NAMI_NOTARY_RESULT"; then
  print -u2 "Notarization submission failed. Details: $NAMI_NOTARY_RESULT"
  cat "$NAMI_NOTARY_RESULT" >&2
  exit 1
fi
python3 - "$NAMI_NOTARY_RESULT" "$NAMI_NOTARY_PROFILE" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
if result.get('status') != 'Accepted':
    print(f"Notarization was not accepted: {result}", file=sys.stderr)
    print(f"Inspect with: xcrun notarytool log {result.get('id', 'SUBMISSION_ID')} --keychain-profile {sys.argv[2]}", file=sys.stderr)
    sys.exit(1)
print('Apple accepted submission ' + result['id'])
PY
xcrun stapler staple "$NAMI_DIST_DIR/Nami.app"
xcrun stapler validate "$NAMI_DIST_DIR/Nami.app"
codesign --verify --deep --strict --verbose=2 "$NAMI_DIST_DIR/Nami.app"
spctl --assess --type execute --verbose=2 "$NAMI_DIST_DIR/Nami.app"
# ZIP after stapling so recipients receive the ticket, including when offline.
ditto -c -k --keepParent "$NAMI_DIST_DIR/Nami.app" "$NAMI_UPLOAD_DIR/Nami-macOS-arm64.zip"
mv -f "$NAMI_UPLOAD_DIR/Nami-macOS-arm64.zip" "$NAMI_DIST_DIR/Nami-macOS-arm64.zip"
print "Ready to share: $NAMI_DIST_DIR/Nami-macOS-arm64.zip"
