#!/usr/bin/env bash
# End-to-end packaging: build Release archive → notarize app → produce a
# signed/notarized/stapled DMG with drag-to-/Applications install.
#
# Usage:
#   scripts/package-dmg.sh                 # reads version from project.yml
#   scripts/package-dmg.sh 0.1.0           # override marketing version
#
# Credentials come from ~/.config/shipyard-macos-gui.env (gitignored) or
# env vars:  APPLE_ID, TEAM_ID, APP_SPECIFIC_PASSWORD,
#            APP_CERT  (Developer ID Application cert name)
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# ── creds ────────────────────────────────────────────────────────────
if [ -f "$HOME/.config/shipyard-macos-gui.env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.config/shipyard-macos-gui.env"
fi
: "${APPLE_ID:?APPLE_ID must be set}"
: "${TEAM_ID:?TEAM_ID must be set}"
: "${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD must be set}"
APP_CERT="${APP_CERT:-Developer ID Application: Daniel Raffel ($TEAM_ID)}"

# ── version ──────────────────────────────────────────────────────────
VERSION="${1:-$(awk '/MARKETING_VERSION/{print $2; exit}' project.yml)}"
[ -n "$VERSION" ] || { echo "Could not determine version" >&2; exit 1; }
echo "Packaging Shipyard v$VERSION"

# ── build Release archive ────────────────────────────────────────────
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE="$BUILD_DIR/ShipyardMenuBar-Release.xcarchive"
APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/Shipyard.app"
STAGING="$BUILD_DIR/dmg-staging"
DMG_OUT="$BUILD_DIR/Shipyard-$VERSION.dmg"

if [ ! -d ShipyardMenuBar.xcodeproj ]; then
  command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
  xcodegen generate
fi

rm -rf "$ARCHIVE"
echo "→ Archiving Release build"
xcodebuild \
  -project ShipyardMenuBar.xcodeproj \
  -scheme ShipyardMenuBar \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  archive \
  | grep -E "^(\*\*|[^/])" | tail -20 || true

[ -d "$APP_IN_ARCHIVE" ] || { echo "Archive did not produce Shipyard.app" >&2; exit 1; }

# ── notarize the .app FIRST (zip → submit → staple) ──────────────────
APP_ZIP="$(mktemp -t shipyard-notarize-app).zip"
echo "→ Zipping .app for notarization"
ditto -c -k --keepParent "$APP_IN_ARCHIVE" "$APP_ZIP"

echo "→ Submitting .app to notary (this can take a few minutes)"
xcrun notarytool submit "$APP_ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

echo "→ Stapling .app"
xcrun stapler staple "$APP_IN_ARCHIVE"
xcrun stapler validate "$APP_IN_ARCHIVE"
rm -f "$APP_ZIP"

# ── build the DMG ────────────────────────────────────────────────────
echo "→ Staging DMG contents"
rm -rf "$STAGING" "$DMG_OUT"
mkdir -p "$STAGING"
cp -R "$APP_IN_ARCHIVE" "$STAGING/"
cp "$PROJECT_ROOT/LICENSE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "→ Creating DMG at $DMG_OUT"
hdiutil create \
  -volname "Shipyard" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_OUT"

# ── sign + notarize + staple the DMG ─────────────────────────────────
echo "→ Signing DMG with $APP_CERT"
codesign --force --sign "$APP_CERT" --options runtime --timestamp "$DMG_OUT"

echo "→ Notarizing DMG"
xcrun notarytool submit "$DMG_OUT" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

echo "→ Stapling DMG"
xcrun stapler staple "$DMG_OUT"
xcrun stapler validate "$DMG_OUT"

rm -rf "$STAGING"

echo
echo "Done: $DMG_OUT"
echo "Ready to upload to a GitHub release."
