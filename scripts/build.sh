#!/usr/bin/env bash
# Build My Miracles for the simulator.
#   scripts/build.sh [Debug|Staging|Release]
set -euo pipefail

CONFIGURATION="${1:-Debug}"
DESTINATION="${MM_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
cd "$(dirname "$0")/.."

xcodebuild \
  -project MyMiracles.xcodeproj \
  -scheme MyMiracles \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath build/DerivedData \
  -quiet \
  build
