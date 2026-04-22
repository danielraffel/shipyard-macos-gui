#!/usr/bin/env bash
# Build ShipyardMenuBar.app via xcodebuild. Produces a signed, hardened-runtime .app.
# Usage: scripts/build.sh [Debug|Release]  (default: Release)
set -euo pipefail

CONFIG=${1:-Release}
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Always regenerate the Xcode project from project.yml. The previous
# "only if missing" guard silently masked MARKETING_VERSION /
# CURRENT_PROJECT_VERSION bumps: xcodegen writes the versions into
# xcconfig at generation time, and xcodebuild caches them there. A
# stale xcodeproj meant every release between v0.1.5 and whatever
# project.yml said at release time shipped the v0.1.5 binary. See
# the post-mortem in the v0.1.8 release thread.
echo "Generating Xcode project via xcodegen…"
xcodegen generate

DERIVED="$PROJECT_ROOT/build/DerivedData"
ARCHIVE="$PROJECT_ROOT/build/ShipyardMenuBar-$CONFIG.xcarchive"
rm -rf "$ARCHIVE"
# Wipe DerivedData too so stale compiled objects from a pre-bump
# generation don't linger with the old MARKETING_VERSION baked in.
rm -rf "$DERIVED"

echo "Building $CONFIG archive → $ARCHIVE"
xcodebuild \
  -project ShipyardMenuBar.xcodeproj \
  -scheme ShipyardMenuBar \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE" \
  archive \
  | xcbeautify 2>/dev/null || true

if [ ! -d "$ARCHIVE" ]; then
  echo "Archive not produced at $ARCHIVE" >&2
  exit 1
fi

echo "Archive produced: $ARCHIVE"
echo "App bundle: $ARCHIVE/Products/Applications/Shipyard.app"
