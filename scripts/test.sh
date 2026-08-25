#!/bin/bash
# Run all unit tests (no hardware required).
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Core
