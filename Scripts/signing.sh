#!/bin/zsh
# Shared by app.sh and distribute.sh. No credentials are stored in the project.
nami_resolve_identity() {
  local identity_file="$NAMI_PROJECT_DIR/.signing-identity"
  local selection="${NAMI_SIGNING_IDENTITY:-}"
  if [[ -z "$selection" && -f "$identity_file" ]]; then
    selection="$(< "$identity_file")"
  fi
  if [[ "$selection" == "-" ]]; then
    print -u2 "Use app.sh --ad-hoc explicitly for a disposable unsigned development build."
    return 1
  fi
  local resolved
  resolved="$(security find-identity -v -p codesigning | python3 -c '
import re, sys
selection = sys.argv[1]
identities = re.findall(r"\b([0-9A-F]{40})\s+\"(Developer ID Application:[^\"]+)\"", sys.stdin.read())
matches = [(fingerprint, name) for fingerprint, name in identities
           if not selection or selection.upper() == fingerprint or selection == name]
if len(matches) != 1:
    print("Nami needs exactly one valid Developer ID Application identity (certificate + private key).", file=sys.stderr)
    if selection:
        print("The selected identity is missing, expired, or ambiguous: " + selection, file=sys.stderr)
    print("In Xcode → Settings → Accounts → your team → Manage Certificates → + → Developer ID Application.", file=sys.stderr)
    print("To select a certificate explicitly: NAMI_SIGNING_IDENTITY=\"full name or SHA-1\" ./Scripts/app.sh", file=sys.stderr)
    for fingerprint, name in identities:
        print(f"  {fingerprint}  {name}", file=sys.stderr)
    sys.exit(1)
print(matches[0][0])
print("Signing as " + matches[0][1], file=sys.stderr)
' "$selection")" || return 1
  NAMI_SIGNING_IDENTITY="$resolved"
}

nami_sign_app() {
  local app_dir="$1"
  local -a signing_options
  signing_options=(--force --sign "$NAMI_SIGNING_IDENTITY" --options runtime)
  if [[ "$NAMI_SIGNING_IDENTITY" == "-" ]]; then
    signing_options+=(--timestamp=none)
  else
    signing_options+=(--timestamp)
  fi
  # Sign embedded code from the inside out. Do not use --deep to sign.
  # Current dependencies link statically; this also covers embedded Swift dylibs.
  local nested
  while IFS= read -r -d '' nested; do
    codesign "${signing_options[@]}" "$nested"
  done < <(find "$app_dir/Contents" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' -o -name '*.xpc' \) -print0)
  codesign "${signing_options[@]}" --entitlements "$NAMI_PROJECT_DIR/Resources/Nami.entitlements" "$app_dir"
  codesign --verify --deep --strict --verbose=2 "$app_dir"
}
