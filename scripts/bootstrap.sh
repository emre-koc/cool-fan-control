#!/bin/bash
# Bootstrap the Xcode project from project.yml (XcodeGen).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate --spec project.yml
echo "OK — open CoolFanControl.xcodeproj"
