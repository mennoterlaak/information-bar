#!/bin/bash
# Renders the Settings window and every provider dropdown with synthetic data into light and
# dark PNGs for layout QA. Reads no account credentials and calls no provider.
# Usage: bash scripts/render-views.sh [output-dir]   (default: .build/visual-qa)
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
output="${1:-.build/visual-qa}"
binary=".build/qa-renderer/render-views"
mkdir -p "$(dirname "$binary")"
# tests/RenderViews.swift supplies its own @main, so the app entry point is left out.
sources=()
for file in Sources/InformationBar/*.swift; do
  [[ "$(basename "$file")" == "App.swift" ]] || sources+=("$file")
done
swiftc -O -parse-as-library -module-name InformationBar -target "$(uname -m)-apple-macos27.0" \
  "${sources[@]}" tests/RenderViews.swift -o "$binary"
# Match the app bundle: record the SDK actually used so renders show the current design.
xcrun vtool -set-build-version macos 27.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$binary.stamped" "$binary" 2>/dev/null && mv "$binary.stamped" "$binary"
"$binary" "$output"
