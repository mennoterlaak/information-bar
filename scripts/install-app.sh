#!/bin/bash
# Builds the app, installs it in /Applications (replacing any earlier copy) and opens it.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
bash "$project_dir/scripts/build-app.sh"
target="/Applications/Information Bar.app"
pkill -x InformationBar 2>/dev/null || true
rm -rf "$target"
cp -R "$project_dir/dist/Information Bar.app" "$target"
open "$target"
printf 'Installed: %s\n' "$target"
