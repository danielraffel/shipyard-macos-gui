#!/usr/bin/env bash
# Tag-triggered, local-only release pipeline.
#
# What it does:
#   1. Validates the current git tag matches project.yml MARKETING_VERSION.
#   2. ./scripts/build.sh Release  (produces the xcarchive)
#   3. xcodebuild -exportArchive → signed .app (Developer ID distribution).
#   4. ./scripts/notarize.sh <app>  (notarizes + staples the .app).
#   5. Verifies the stapled .app.
#   6. hdiutil create → dist/Shipyard.dmg  (STABLE name, no version).
#   7. Staples + validates the DMG.
#   8. gh release create / upload --clobber so re-runs on the same tag
#      are idempotent.
#
# Never runs in CI. Never triggers on push. Only on explicit invocation
# with a git tag `v<X.Y.Z>` on HEAD. Apple creds read from
# ~/.config/shipyard-macos-gui.env (NEVER echoed).
#
# Usage:
#   git tag v1.0.0
#   git push --tags
#   ./scripts/release.sh           # uses tag on HEAD
#   ./scripts/release.sh v1.0.0    # explicit override
#   ./scripts/release.sh v1.0.0 --draft    # don't publish yet
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

REPO="danielraffel/shipyard-macos-gui"

# ── creds (loaded silently) ─────────────────────────────────────────
if [ -f "$HOME/.config/shipyard-macos-gui.env" ]; then
  # shellcheck disable=SC1090
  set +u; source "$HOME/.config/shipyard-macos-gui.env"; set -u
fi
: "${APPLE_ID:?APPLE_ID not set — add to ~/.config/shipyard-macos-gui.env}"
: "${TEAM_ID:?TEAM_ID not set — add to ~/.config/shipyard-macos-gui.env}"
: "${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD not set — add to ~/.config/shipyard-macos-gui.env}"

# ── tag resolution + validation ─────────────────────────────────────
TAG="${1:-}"
if [ -z "$TAG" ] || [[ "$TAG" == --* ]]; then
  TAG=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
fi
if [ -z "$TAG" ]; then
  echo "ERROR: No tag on HEAD and no tag argument." >&2
  echo "Create one first:  git tag v1.0.0 && git push --tags" >&2
  exit 1
fi
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "ERROR: Tag '$TAG' doesn't match v<X.Y.Z>[-<prerelease>]" >&2
  exit 1
fi
# Strip any pre-release suffix before version-match checks so a
# dry-run tag like v0.0.0-dryrun still maps to project.yml's 0.0.0.
RAW="${TAG#v}"
VERSION="${RAW%%-*}"

# Honor a trailing --draft flag to create a draft release (useful for
# dry-runs). Shift past the tag arg if present.
DRAFT_FLAG=""
for arg in "$@"; do
  [ "$arg" = "--draft" ] && DRAFT_FLAG="--draft"
done

# ── version drift check ─────────────────────────────────────────────
PROJECT_VERSION=$(awk '/MARKETING_VERSION/{print $2; exit}' project.yml | tr -d '"')
if [ -z "$PROJECT_VERSION" ]; then
  echo "ERROR: Could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi
if [ "$PROJECT_VERSION" != "$VERSION" ]; then
  echo "ERROR: Tag version ($VERSION) != project.yml MARKETING_VERSION ($PROJECT_VERSION)" >&2
  echo "Bump project.yml, commit, re-tag, and retry." >&2
  exit 1
fi

echo "▶︎ Releasing $TAG (project.yml in sync at $PROJECT_VERSION)"
[ -n "$DRAFT_FLAG" ] && echo "  (dry-run: will create a draft release)"

# ── step 1: archive via build.sh ────────────────────────────────────
echo "→ Building Release archive"
./scripts/build.sh Release

ARCHIVE="build/ShipyardMenuBar-Release.xcarchive"
[ -d "$ARCHIVE" ] || { echo "ERROR: Expected archive missing at $ARCHIVE" >&2; exit 1; }

# ── step 2: export signed .app via exportArchive ────────────────────
EXPORT_ROOT=$(mktemp -d)
trap 'rm -rf "$EXPORT_ROOT"' EXIT

cat > "$EXPORT_ROOT/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF

echo "→ Exporting signed .app (Developer ID, hardened, timestamp)"
xcrun xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_ROOT/out" \
  -exportOptionsPlist "$EXPORT_ROOT/exportOptions.plist" \
  >"$EXPORT_ROOT/export.log" 2>&1 || {
    echo "ERROR: exportArchive failed. Tail of log:" >&2
    tail -30 "$EXPORT_ROOT/export.log" >&2
    exit 1
  }

APP_PATH=$(find "$EXPORT_ROOT/out" -maxdepth 3 -name "*.app" -type d | head -1)
[ -d "$APP_PATH" ] || { echo "ERROR: No .app produced by exportArchive" >&2; exit 1; }
echo "  → $APP_PATH"

# ── step 3: notarize the .app ───────────────────────────────────────
echo "→ Notarizing .app"
./scripts/notarize.sh "$APP_PATH"

# ── step 4: verify staple ───────────────────────────────────────────
echo "→ Verifying .app staple"
xcrun stapler validate "$APP_PATH" \
  || { echo "ERROR: .app not stapled after notarize.sh" >&2; exit 1; }

# ── step 5: build DMG with stable name ──────────────────────────────
DIST_DIR="$PROJECT_ROOT/dist"
mkdir -p "$DIST_DIR"
DMG="$DIST_DIR/Shipyard.dmg"
rm -f "$DMG"

STAGE=$(mktemp -d)
trap 'rm -rf "$EXPORT_ROOT" "$STAGE"' EXIT

cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[ -f LICENSE ] && cp LICENSE "$STAGE/"

echo "→ Creating DMG → $DMG"
xcrun hdiutil create \
  -volname "Shipyard" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

# ── step 6: notarize the DMG, then staple + verify ──────────────────
# Stapling needs a notarization ticket keyed by the DMG's own SHA —
# the .app submission from step 3 doesn't produce one for the DMG.
# Submit the DMG itself, wait for acceptance, then staple.
echo "→ Notarizing DMG"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait \
  || { echo "ERROR: notarytool rejected DMG" >&2; exit 1; }

echo "→ Stapling DMG"
xcrun stapler staple "$DMG" \
  || { echo "ERROR: stapler staple failed on DMG" >&2; exit 1; }
xcrun stapler validate "$DMG" \
  || { echo "ERROR: DMG staple didn't validate" >&2; exit 1; }

# ── step 7: generate release notes (dogfood shipyard changelog) ─────
# Prefer `shipyard changelog regenerate --release-notes <tag>` so this
# repo exercises the same automation the main shipyard project ships.
# Falls back to `gh release create --generate-notes` if the CLI or
# config isn't available.
NOTES_FILE=""
SHIPYARD_BIN=""
for candidate in "$HOME/.pulp/bin/shipyard" "$(command -v shipyard || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    SHIPYARD_BIN="$candidate"
    break
  fi
done
if [ -n "$SHIPYARD_BIN" ] && [ -f "$PROJECT_ROOT/.shipyard/config.toml" ]; then
  NOTES_FILE="$EXPORT_ROOT/release-notes.md"
  echo "→ Generating release notes via $SHIPYARD_BIN"
  if "$SHIPYARD_BIN" changelog regenerate --release-notes "$TAG" \
      >"$NOTES_FILE" 2>"$EXPORT_ROOT/notes.err"; then
    if [ ! -s "$NOTES_FILE" ]; then
      echo "  (shipyard produced empty notes — falling back to --generate-notes)"
      NOTES_FILE=""
    fi
  else
    echo "  (shipyard changelog failed — falling back to --generate-notes)"
    tail -20 "$EXPORT_ROOT/notes.err" >&2 || true
    NOTES_FILE=""
  fi
fi

# ── step 8: publish to GitHub Releases ──────────────────────────────
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "→ Release $TAG exists — uploading DMG with --clobber"
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  if [ -n "$NOTES_FILE" ]; then
    echo "→ Updating release body from shipyard notes"
    gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES_FILE"
  fi
else
  echo "→ Creating GitHub release $TAG"
  if [ -n "$NOTES_FILE" ]; then
    gh release create "$TAG" "$DMG" \
      --repo "$REPO" \
      --title "Shipyard $TAG" \
      --notes-file "$NOTES_FILE" \
      $DRAFT_FLAG
  else
    gh release create "$TAG" "$DMG" \
      --repo "$REPO" \
      --title "Shipyard $TAG" \
      --generate-notes \
      $DRAFT_FLAG
  fi
fi

# ── step 9: refresh CHANGELOG.md in the repo (best-effort) ──────────
# The post-tag hook in .shipyard/config.toml would do this via a bot
# push, but we also refresh locally so a follow-up commit captures it
# if the bot path isn't wired up yet.
if [ -n "$SHIPYARD_BIN" ] && [ -f "$PROJECT_ROOT/.shipyard/config.toml" ]; then
  echo "→ Regenerating CHANGELOG.md"
  "$SHIPYARD_BIN" changelog regenerate >/dev/null 2>&1 || \
    echo "  (changelog regenerate skipped — non-fatal)"
fi

echo
echo "✓ Done"
echo "  Release:    https://github.com/$REPO/releases/tag/$TAG"
echo "  Stable URL: https://github.com/$REPO/releases/latest/download/Shipyard.dmg"
