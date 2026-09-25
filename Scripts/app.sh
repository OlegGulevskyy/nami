#!/bin/zsh
set -euo pipefail
NAMI_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$NAMI_PROJECT_DIR"
NAMI_BUILD_CONFIGURATION="${NAMI_BUILD_CONFIGURATION:-release}"
if [[ "${1:-}" != "--package-only" ]]; then
  swift build -c "$NAMI_BUILD_CONFIGURATION" --product Nami
fi
NAMI_APP_DIR="$NAMI_PROJECT_DIR/.build/Nami.app"
mkdir -p "$NAMI_APP_DIR/Contents/MacOS" "$NAMI_APP_DIR/Contents/Resources"
cp ".build/$NAMI_BUILD_CONFIGURATION/Nami" "$NAMI_APP_DIR/Contents/MacOS/Nami.new"
mv -f "$NAMI_APP_DIR/Contents/MacOS/Nami.new" "$NAMI_APP_DIR/Contents/MacOS/Nami"
cp Resources/App-Info.plist "$NAMI_APP_DIR/Contents/Info.plist"
# Keep resources in the standard macOS location. With this local SwiftPM build,
# Bundle.module also retains its absolute .build resource fallback.
for NAMI_RESOURCE_BUNDLE in .build/$NAMI_BUILD_CONFIGURATION/*.bundle(N); do
  ditto "$NAMI_RESOURCE_BUNDLE" "$NAMI_APP_DIR/Contents/Resources/$(basename "$NAMI_RESOURCE_BUNDLE")"
done
python3 - "$NAMI_PROJECT_DIR" "$NAMI_APP_DIR" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[2], 'Contents/Resources/workspace.json').write_text(json.dumps({'project': sys.argv[1]}))
PY
# An explicitly selected, installed identity preserves permission identity across
# rebuilds. The default remains local ad-hoc signing and needs no credentials.
NAMI_SIGNING_IDENTITY="${NAMI_SIGNING_IDENTITY:--}"
codesign --force --sign "$NAMI_SIGNING_IDENTITY" "$NAMI_APP_DIR"
if [[ "$NAMI_SIGNING_IDENTITY" == "-" ]]; then
  print -u2 "Nami uses ad-hoc signing: rebuilding can invalidate Input Monitoring permission."
  print -u2 "If Nami is enabled but shortcuts still fail, quit Nami and run: tccutil reset ListenEvent local.nami.studio"
  print -u2 "Then reopen this app and grant Input Monitoring again. Toggling an old entry may retain the previous build's identity."
fi
if [[ "${1:-}" != "--package-only" ]]; then
  open "$NAMI_APP_DIR"
else
  print "$NAMI_APP_DIR"
fi
