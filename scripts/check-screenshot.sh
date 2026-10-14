#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${NOTCHHUB_SDK:-$(xcrun --show-sdk-path)}"
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
SOURCES=()
for source in Sources/NotchHub/*.swift; do
    [[ "$source" == "Sources/NotchHub/App.swift" ]] || SOURCES+=("$source")
done
xcrun swiftc -sdk "$SDK" "${SOURCES[@]}" scripts/ScreenshotChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
