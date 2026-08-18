#!/usr/bin/env bash
# Run the My Miracles test suites.
#   scripts/test.sh            unit + UI
#   scripts/test.sh unit       unit only (fast — use this in a tight loop)
set -euo pipefail

SCOPE="${1:-all}"
DESTINATION="${MM_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
cd "$(dirname "$0")/.."

ARGS=(
  -project MyMiracles.xcodeproj
  -scheme MyMiracles
  -configuration Debug
  -destination "$DESTINATION"
  -derivedDataPath build/DerivedData
)
[[ "$SCOPE" == "unit" ]] && ARGS+=(-only-testing:MyMiraclesTests)

xcodebuild "${ARGS[@]}" test
