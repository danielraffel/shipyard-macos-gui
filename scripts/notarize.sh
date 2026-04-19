#!/usr/bin/env bash
# Notarize a signed .app with Apple's notary service, then staple the ticket.
# Reads creds from ~/.config/shipyard-macos-gui.env (gitignored) or env vars:
#   APPLE_ID, TEAM_ID, APP_SPECIFIC_PASSWORD
#
# Usage: scripts/notarize.sh path/to/Shipyard.app
set -euo pipefail

APP="${1:?Usage: notarize.sh path/to/Shipyard.app}"

if [ -f "$HOME/.config/shipyard-macos-gui.env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.config/shipyard-macos-gui.env"
fi

: "${APPLE_ID:?APPLE_ID must be set}"
: "${TEAM_ID:?TEAM_ID must be set}"
: "${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD must be set}"

ZIP=$(mktemp -t shipyard-notarize).zip
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting for notarization…"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

echo "Stapling ticket to $APP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
echo "Notarization complete: $APP"
