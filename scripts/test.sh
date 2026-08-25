#!/bin/bash
# Run contracts, Core unit tests, and native macOS build verification.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -v
swift test --package-path Core
scripts/bootstrap.sh
xcodebuild -project CoolFanControl.xcodeproj -scheme CoolFanControl -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project CoolFanControl.xcodeproj -scheme helperd -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
