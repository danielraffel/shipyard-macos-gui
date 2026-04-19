#!/usr/bin/env bash
# Build ShipyardMenuBar.app via xcodebuild. Produces a signed, hardened-runtime .app.
# Usage: scripts/build.sh [Debug|Release]  (default: Release)
set -euo pipefail

CONFIG=${1:-Release}
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if [ ! -d ShipyardMenuBar.xcodeproj ]; then
  echo "Generating Xcode project via xcodegen…"
  xcodegen generate
fi

DERIVED="$PROJECT_ROOT/build/DerivedData"
ARCHIVE="$PROJECT_ROOT/build/ShipyardMenuBar-$CONFIG.xcarchive"
rm -rf "$ARCHIVE"

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
