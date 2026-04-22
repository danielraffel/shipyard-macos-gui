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
# CURRENT_PROJECT_VERSION is the monotonic build number (CFBundleVersion
# in the built app). Sparkle's default version comparator reads it off
# the running app to decide whether an appcast entry is an upgrade, so
# we MUST emit it into <sparkle:version>. Using the marketing string
# there (e.g. "0.1.10") would lose against the stored build number
# ("10") under Sparkle's numeric-segment comparator, and the user would
# never get offered the update.
BUILD_NUMBER=$(awk '/CURRENT_PROJECT_VERSION/{print $2; exit}' project.yml | tr -d '"')
if [ -z "$PROJECT_VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
  echo "ERROR: Could not read MARKETING_VERSION or CURRENT_PROJECT_VERSION from project.yml" >&2
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

# ── step 7b: Sparkle EdDSA signature + per-release HTML notes ───────
# Sparkle verifies every update with EdDSA. sign_update reads the
# private key from the macOS Keychain (the same key generate_keys
# wrote); our Info.plist embeds the matching SUPublicEDKey. If the
# signature isn't emitted here, Sparkle refuses to install the update
# on the user's machine — the app looks broken, no error reaches the
# user beyond a one-line dialog.
SPARKLE_ARTIFACTS=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*ShipyardMenuBar*/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    -type d 2>/dev/null | head -1)
if [ -z "$SPARKLE_ARTIFACTS" ] || [ ! -x "$SPARKLE_ARTIFACTS/sign_update" ]; then
  echo "ERROR: Sparkle sign_update tool not found. Expected under DerivedData/…/Sparkle/bin" >&2
  echo "  Run a build through Xcode once so SPM resolves the Sparkle artifacts." >&2
  exit 1
fi
echo "→ Signing DMG with Sparkle (sign_update)"
SIGN_OUT=$("$SPARKLE_ARTIFACTS/sign_update" "$DMG") || {
  echo "ERROR: sign_update failed. Does your Keychain have the EdDSA private key?" >&2
  echo "       Run '$SPARKLE_ARTIFACTS/generate_keys' once to create it." >&2
  exit 1
}
# Output looks like:
#   sparkle:edSignature="..." length="2959383"
# Extract the signature + length for the appcast entry.
ED_SIGNATURE=$(echo "$SIGN_OUT" | sed -E 's/.*edSignature="([^"]+)".*/\1/')
ED_LENGTH=$(echo "$SIGN_OUT" | sed -E 's/.*length="([^"]+)".*/\1/')
if [ -z "$ED_SIGNATURE" ] || [ -z "$ED_LENGTH" ]; then
  echo "ERROR: couldn't parse sign_update output: $SIGN_OUT" >&2
  exit 1
fi

# Per-release HTML page. Sparkle's update window renders this inline,
# so the user reads "what's new" before clicking Install. We derive
# it from the markdown notes shipyard-changelog already emits.
RELEASE_HTML="$EXPORT_ROOT/release-notes-$TAG.html"
RELEASE_HTML_ASSET_NAME="release-notes-$TAG.html"
if [ -n "$NOTES_FILE" ] && [ -s "$NOTES_FILE" ]; then
  NOTES_MD=$(cat "$NOTES_FILE")
else
  NOTES_MD="See https://github.com/$REPO/releases/tag/$TAG for details."
fi
cat > "$RELEASE_HTML" <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Shipyard $TAG</title>
<style>
  body { font: 13px/1.5 -apple-system, system-ui, sans-serif;
         color: #1d1d1f; margin: 16px 20px; }
  body.dark { background: #1d1d1f; color: #f5f5f7; }
  h1, h2, h3 { font-weight: 600; margin-top: 1.2em; }
  h1 { font-size: 18px; margin-top: 0; }
  h2 { font-size: 15px; }
  code { background: rgba(0,0,0,0.06); padding: 1px 4px; border-radius: 3px;
         font: 12px ui-monospace, SFMono-Regular, monospace; }
  body.dark code { background: rgba(255,255,255,0.10); }
  pre { background: rgba(0,0,0,0.06); padding: 10px; border-radius: 6px;
        overflow-x: auto; }
  body.dark pre { background: rgba(255,255,255,0.08); }
  a { color: #0066cc; }
  ul { padding-left: 1.2em; }
  .meta { color: #6e6e73; font-size: 11px; margin-top: 2px; }
</style>
<script>
  // Respect Sparkle's dark-mode host so our notes window matches the
  // update dialog chrome.
  if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
    document.documentElement.addEventListener('DOMContentLoaded', function() {
      document.body.classList.add('dark');
    });
    document.addEventListener('DOMContentLoaded', function() {
      document.body.classList.add('dark');
    });
  }
</script>
</head><body>
<h1>Shipyard $TAG</h1>
<div class="meta">Released $(date -u +%Y-%m-%d)</div>
HTML
# Convert markdown to minimal HTML. We deliberately keep this tiny
# rather than pull a full markdown dep — the notes generated by
# `shipyard changelog` are simple list-of-commits, so headings + ul
# + code is all we need. Anything more elaborate falls back to <pre>.
if command -v pandoc >/dev/null 2>&1; then
  pandoc -f gfm -t html "$NOTES_FILE" >> "$RELEASE_HTML" 2>/dev/null || \
    printf '<pre>%s</pre>\n' "$(echo "$NOTES_MD" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')" >> "$RELEASE_HTML"
else
  printf '<pre>%s</pre>\n' "$(echo "$NOTES_MD" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')" >> "$RELEASE_HTML"
fi
cat >> "$RELEASE_HTML" <<HTML
<div class="meta" style="margin-top: 24px;">
  Full history: <a href="https://github.com/$REPO/releases">GitHub Releases</a>
</div>
</body></html>
HTML

# Appcast. We regenerate the full file each release — not by hand,
# but via `generate_appcast` which walks the dist-local archive.
# That tool wants every versioned DMG in one directory; we don't
# maintain that locally, so instead we build the appcast entry
# by hand and merge it into a cumulative file pulled from the
# previous release (if any). This keeps the appcast self-contained
# and immutable per release.
APPCAST="$EXPORT_ROOT/appcast.xml"
PREV_APPCAST="$EXPORT_ROOT/appcast-prev.xml"
# Try to pull the previous appcast so we accumulate history; if
# this is the first Sparkle release the fetch 404s and we start
# fresh with just the new entry.
if gh release download --repo "$REPO" --pattern appcast.xml \
    --dir "$EXPORT_ROOT" 2>/dev/null; then
  mv "$EXPORT_ROOT/appcast.xml" "$PREV_APPCAST"
fi

DMG_URL="https://github.com/$REPO/releases/download/$TAG/Shipyard.dmg"
RELEASE_HTML_URL="https://github.com/$REPO/releases/download/$TAG/$RELEASE_HTML_ASSET_NAME"
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

NEW_ITEM=$(cat <<XML
    <item>
      <title>Shipyard $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$RELEASE_HTML_URL</sparkle:releaseNotesLink>
      <enclosure url="$DMG_URL"
                 sparkle:edSignature="$ED_SIGNATURE"
                 length="$ED_LENGTH"
                 type="application/octet-stream" />
    </item>
XML
)

{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  echo '  <channel>'
  echo '    <title>Shipyard</title>'
  echo '    <link>https://github.com/'"$REPO"'</link>'
  echo '    <description>Menu-bar companion for the Shipyard CI CLI.</description>'
  echo '    <language>en</language>'
  echo "$NEW_ITEM"
  # Append every prior <item> block from the previous appcast. Not
  # a full XML parse — `awk` pulls each <item>…</item> block as-is,
  # skipping the one whose sparkle:shortVersionString matches the
  # current $VERSION (so a re-run of the same tag doesn't duplicate).
  if [ -f "$PREV_APPCAST" ]; then
    awk -v current="$VERSION" '
      /<item>/ { inside=1; buf=""; skip=0 }
      inside { buf = buf $0 "\n" }
      inside && /<sparkle:shortVersionString>/ {
        match($0, /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/, m)
        if (m[1] == current) skip=1
      }
      /<\/item>/ { if (!skip) printf "%s", buf; inside=0 }
    ' "$PREV_APPCAST"
  fi
  echo '  </channel>'
  echo '</rss>'
} > "$APPCAST"

# ── step 8: publish to GitHub Releases ──────────────────────────────
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "→ Release $TAG exists — uploading DMG + Sparkle assets with --clobber"
  gh release upload "$TAG" "$DMG" "$APPCAST" "$RELEASE_HTML" \
    --repo "$REPO" --clobber
  if [ -n "$NOTES_FILE" ]; then
    echo "→ Updating release body from shipyard notes"
    gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES_FILE"
  fi
else
  echo "→ Creating GitHub release $TAG (with appcast + release notes page)"
  if [ -n "$NOTES_FILE" ]; then
    gh release create "$TAG" "$DMG" "$APPCAST" "$RELEASE_HTML" \
      --repo "$REPO" \
      --title "Shipyard $TAG" \
      --notes-file "$NOTES_FILE" \
      $DRAFT_FLAG
  else
    gh release create "$TAG" "$DMG" "$APPCAST" "$RELEASE_HTML" \
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
