#!/bin/zsh
# Builds, verifies and zips Hephaestus for a GitHub release.
#   ./release.sh             build + package only (nothing is published)
#   ./release.sh --publish   also create the GitHub release v<version> from main
# The version comes from Sources/HephaestusIPC/Version.swift (same source as build.sh).
set -euo pipefail
cd "$(dirname "$0")"

PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1
[[ $# -le 1 && ( $# -eq 0 || "$1" == "--publish" ) ]] || { echo "usage: ./release.sh [--publish]"; exit 2; }

VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/HephaestusIPC/Version.swift)
[[ -n "$VERSION" ]] || { echo "Could not read the version from Version.swift"; exit 1; }
TAG="v$VERSION"
ZIP="build/Hephaestus-$VERSION.zip"
SIG="$ZIP.sig"
SIGNING_KEY="${HEPHAESTUS_SIGNING_KEY:-$HOME/.hephaestus/update-signing.key}"
# The public key the app trusts, read from the one constant in the Swift source (see UpdateKey.swift).
PUBKEY=$(sed -n 's/.*static let publicKeyBase64 = "\(.*\)".*/\1/p' Sources/HephaestusCore/UpdateKey.swift)

if (( PUBLISH )); then
  [[ "$(git branch --show-current)" == "main" ]] || { echo "Publish from the main branch."; exit 1; }
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Working tree has uncommitted changes."; exit 1; }
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not in sync with origin/main (pull or push first)."; exit 1; }
  [[ -n "$PUBKEY" ]] || { echo "UpdateKey.publicKeyBase64 is empty: builds would never accept updates. Generate a key (README > Updates) and paste the public key first."; exit 1; }
  [[ -f "$SIGNING_KEY" ]] || { echo "Signing key not found at $SIGNING_KEY (set HEPHAESTUS_SIGNING_KEY). Refusing to publish an unsigned release."; exit 1; }
  if gh release view "$TAG" >/dev/null 2>&1; then echo "Release $TAG already exists; bump the version in Version.swift."; exit 1; fi
fi

./build.sh
APP=build/Hephaestus.app
codesign --verify --deep --strict "$APP"
[[ -x "$APP/Contents/MacOS/hephaestus-cli" ]] || { echo "CLI missing from the app bundle."; exit 1; }

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"   # ditto keeps the code signature intact (plain zip may not)

rm -f "$SIG"
if [[ -f "$SIGNING_KEY" ]]; then
  swift run -q -c release hephaestus-sign sign "$SIGNING_KEY" "$ZIP"
  if [[ -n "$PUBKEY" ]]; then
    swift run -q -c release hephaestus-sign verify "$PUBKEY" "$ZIP" "$SIG" || { echo "Signature does not verify against UpdateKey.publicKeyBase64 (wrong key file?)."; rm -f "$SIG"; exit 1; }
  else
    echo "WARNING: UpdateKey.publicKeyBase64 is empty, so the signature could not be checked against the app's key."
  fi
else
  echo "WARNING: no signing key at $SIGNING_KEY; no .sig produced. Installed apps would reject this release."
fi
SUM=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

echo
echo "Built $ZIP"
echo "SHA-256: $SUM"
[[ -f "$SIG" ]] && echo "Signature: $SIG"
if codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "Signed with a Developer ID. Notarize before publishing (xcrun notarytool submit ... --wait; xcrun stapler staple)."
else
  echo "NOTE: not signed with a Developer ID and not notarized; macOS will warn users on first launch (see README > Install)."
fi

if (( PUBLISH )); then
  [[ -n "$PUBKEY" && -f "$SIG" ]] && swift run -q -c release hephaestus-sign verify "$PUBKEY" "$ZIP" "$SIG" >/dev/null \
    || { echo "Refusing to publish: $SIG is missing or does not verify against UpdateKey.publicKeyBase64."; exit 1; }
fi

if (( ! PUBLISH )); then
  echo "Not published. Run ./release.sh --publish from main to create release $TAG."
  exit 0
fi

NOTES=$(cat <<NOTES_EOF
Hephaestus $VERSION, a FancyZones-style window manager for macOS (13+).

**Install:** unzip, move \`Hephaestus.app\` to \`/Applications\`, open it, and grant it Accessibility
(System Settings > Privacy & Security > Accessibility).

The app is not notarized. If macOS says it cannot verify the developer, open
System Settings > Privacy & Security and click **Open Anyway**, or run:
\`xattr -dr com.apple.quarantine /Applications/Hephaestus.app\`

**Updates:** the zip is signed (Ed25519, \`Hephaestus-$VERSION.zip.sig\`). Installed apps verify the signature
before installing an update, so only releases signed with the project key are accepted.

SHA-256 of the zip: \`$SUM\`

See the [README](https://github.com/gianlucanotaro/hephaestus#readme) for features, shortcuts and settings.
NOTES_EOF
)
gh release create "$TAG" "$ZIP" "$SIG" --target main --title "Hephaestus $VERSION" --notes "$NOTES"
echo "Published: $(gh release view "$TAG" --json url -q .url)"
