#!/bin/zsh
set -euo pipefail
NAMI_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$NAMI_PROJECT_DIR"
source Scripts/signing.sh

NAMI_PACKAGE_ONLY=0
NAMI_OPEN=1
NAMI_DISTRIBUTION=0
NAMI_AD_HOC=0
for argument in "$@"; do
  case "$argument" in
    --package-only) NAMI_PACKAGE_ONLY=1; NAMI_OPEN=0 ;;
    --no-open) NAMI_OPEN=0 ;;
    --distribution) NAMI_DISTRIBUTION=1; NAMI_OPEN=0 ;;
    --ad-hoc) NAMI_AD_HOC=1 ;;
    --check-signing) nami_resolve_identity; exit ;;
    --help)
      print 'Usage: ./Scripts/app.sh [--no-open] [--package-only] [--distribution] [--ad-hoc]'
      print 'Default: incrementally build, Developer ID sign, and open .build/Nami.app.'
      print -r -- '--distribution: release app without checkout paths in .build/distribution/Nami.app.'
      print -r -- '--package-only: repackage the last Xcode build without compiling or launching.'
      print -r -- '--ad-hoc: explicit local fallback; permissions may reset. Never for distribution.'
      print -r -- '--check-signing: verify that a Developer ID Application identity is available.'
      exit ;;
    *) print -u2 "Unknown argument: $argument"; exit 1 ;;
  esac
done
if (( NAMI_AD_HOC )); then
  if (( NAMI_DISTRIBUTION )); then
    print -u2 'Distribution requires a Developer ID Application certificate.'
    exit 1
  fi
  NAMI_SIGNING_IDENTITY=-
else
  nami_resolve_identity
fi

case "${NAMI_BUILD_CONFIGURATION:-release}" in
  release|Release) NAMI_CONFIGURATION=Release ;;
  debug|Debug) NAMI_CONFIGURATION=Debug ;;
  *) print -u2 'NAMI_BUILD_CONFIGURATION must be debug or release.'; exit 1 ;;
esac
NAMI_OUTPUT_DIR="$NAMI_PROJECT_DIR/.build"
if (( NAMI_DISTRIBUTION )); then
  NAMI_CONFIGURATION=Release
  NAMI_OUTPUT_DIR="$NAMI_OUTPUT_DIR/distribution"
fi
if (( ! NAMI_PACKAGE_ONLY )); then
  # Xcode generates resource accessors that support Contents/Resources. A plain
  # `swift build` executable instead depends on its original .build directory.
  xcodebuild -quiet -project Nami.xcodeproj -scheme Nami \
    -configuration "$NAMI_CONFIGURATION" -derivedDataPath .build/xcode \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
fi
NAMI_BUILT_APP="$NAMI_PROJECT_DIR/.build/xcode/Build/Products/$NAMI_CONFIGURATION/Nami.app"
if [[ ! -d "$NAMI_BUILT_APP" ]]; then
  print -u2 'No Xcode app build found. Run ./Scripts/app.sh without --package-only first.'
  exit 1
fi
mkdir -p "$NAMI_OUTPUT_DIR"
NAMI_STAGING_DIR="$(mktemp -d "$NAMI_OUTPUT_DIR/.package.XXXXXX")"
# Zsh can skip EXIT when ERR_EXIT terminates inside a function.
trap 'rm -rf "$NAMI_STAGING_DIR"' EXIT ZERR
NAMI_STAGED_APP="$NAMI_STAGING_DIR/Nami.app"
ditto "$NAMI_BUILT_APP" "$NAMI_STAGED_APP"
rm -f "$NAMI_STAGED_APP/Contents/Resources/workspace.json"
if (( ! NAMI_DISTRIBUTION )); then
  python3 - "$NAMI_PROJECT_DIR" "$NAMI_STAGED_APP" <<'PYTHON'
import json, sys
from pathlib import Path
resources = Path(sys.argv[2], 'Contents/Resources')
resources.mkdir(parents=True, exist_ok=True)
(resources / 'workspace.json').write_text(json.dumps({'project': sys.argv[1]}))
PYTHON
fi
nami_sign_app "$NAMI_STAGED_APP"

# Leave the last working app intact if compilation or signing fails.
NAMI_APP_DIR="$NAMI_OUTPUT_DIR/Nami.app"
if [[ -d "$NAMI_APP_DIR" ]]; then
  mv "$NAMI_APP_DIR" "$NAMI_STAGING_DIR/previous.app"
fi
if ! mv "$NAMI_STAGED_APP" "$NAMI_APP_DIR"; then
  [[ ! -d "$NAMI_STAGING_DIR/previous.app" ]] || mv "$NAMI_STAGING_DIR/previous.app" "$NAMI_APP_DIR"
  exit 1
fi
if (( NAMI_AD_HOC )); then
  print -u2 'Ad-hoc build: changed executables can invalidate privacy permissions.'
else
  # Pin the certificate after successful signing so adding another certificate
  # never silently changes the identity used for the next rebuild.
  print -r -- "$NAMI_SIGNING_IDENTITY" > .signing-identity
fi
print -r -- "$NAMI_APP_DIR"
if (( NAMI_OPEN )); then
  open "$NAMI_APP_DIR"
fi
