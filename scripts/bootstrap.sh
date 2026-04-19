#!/usr/bin/env bash
# First-run setup: generate Xcode project, verify toolchain + signing identity.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen"
  exit 1
fi

xcodegen generate

echo
echo "Signing identity check:"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  security find-identity -v -p codesigning | grep "Developer ID Application" | head -3
else
  echo "  (no Developer ID Application cert found — sign-less debug builds still work)"
fi

echo
echo "Done. Open ShipyardMenuBar.xcodeproj in Xcode, or run scripts/build.sh."
