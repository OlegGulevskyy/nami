#!/bin/bash
# GitHub-hosted runner only. Secrets arrive through environment variables.
set -euo pipefail
set +x
: "${RUNNER_TEMP:?Run this on a GitHub-hosted macOS runner}"
for name in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD SPARKLE_PRIVATE_KEY APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing GitHub Actions secret: $name" >&2
    exit 1
  fi
done
umask 077
NAMI_CI_KEYCHAIN="$RUNNER_TEMP/nami-signing.keychain-db"
NAMI_CI_KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$NAMI_CI_KEYCHAIN_PASSWORD"
export NAMI_CI_KEYCHAIN_PASSWORD
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP'])
(root / 'nami-certificate.p12').write_bytes(base64.b64decode(os.environ['MACOS_CERTIFICATE_P12_BASE64'], validate=True))
(root / 'nami-sparkle.key').write_text(os.environ['SPARKLE_PRIVATE_KEY'])
PY
security create-keychain -p "$NAMI_CI_KEYCHAIN_PASSWORD" "$NAMI_CI_KEYCHAIN"
security set-keychain-settings -lut 21600 "$NAMI_CI_KEYCHAIN"
security unlock-keychain -p "$NAMI_CI_KEYCHAIN_PASSWORD" "$NAMI_CI_KEYCHAIN"
security import "$RUNNER_TEMP/nami-certificate.p12" -P "$MACOS_CERTIFICATE_PASSWORD" \
  -k "$NAMI_CI_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$NAMI_CI_KEYCHAIN_PASSWORD" "$NAMI_CI_KEYCHAIN" >/dev/null
security list-keychains -d user -s "$NAMI_CI_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
security default-keychain -d user -s "$NAMI_CI_KEYCHAIN"
xcrun notarytool store-credentials nami-notary --keychain "$NAMI_CI_KEYCHAIN" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" >/dev/null
rm -f "$RUNNER_TEMP/nami-certificate.p12"
echo "NAMI_SPARKLE_KEY_FILE=$RUNNER_TEMP/nami-sparkle.key" >> "$GITHUB_ENV"
