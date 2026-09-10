#!/bin/bash
# Captures the README screenshots from the built app running on synthetic data (--demo):
# the Settings window and the Claude and Vast.ai dropdowns, as macOS draws them.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
app="dist/Information Bar.app/Contents/MacOS/InformationBar"
[ -x "$app" ] || bash scripts/build-app.sh
out="docs/screenshots"
mkdir -p "$out"

capture() {  # capture <launch flags> <log marker> <output png>
  local log; log="$(mktemp)"
  "$app" --demo $1 --exit-after 6 > "$log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 40); do grep -q "$2" "$log" && break; sleep 0.1; done
  sleep 1.5  # let SwiftUI finish drawing
  local id; id="$(grep -o "$2 [0-9]*" "$log" | awk '{print $NF}')"
  screencapture -x -o -l "$id" "$3"
  wait $pid || true
  rm -f "$log"
  printf 'captured %s\n' "$3"
}

capture "--settings" "settings window" "$out/settings.png"
capture "--panel claude" "panel window" "$out/claude-dropdown.png"
capture "--panel vast" "panel window" "$out/vast-dropdown.png"
