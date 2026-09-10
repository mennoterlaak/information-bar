#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# Single source of truth for the version: Settings and the collector read it from the bundle.
version="1.0.0"
build="5"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/Information Bar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/InformationBar" "$app_dir/Contents/MacOS/InformationBar"
# SwiftPM stamps the deployment target as the SDK version. macOS reads that field to decide
# whether an app gets the current design (Liquid Glass on macOS 26 and later) or the
# compatibility look, so record the SDK the binary was actually built against.
sdk_version="$(xcrun --show-sdk-version)"
xcrun vtool -set-build-version macos 27.0 "$sdk_version" -replace \
  -output "$app_dir/Contents/MacOS/InformationBar.stamped" "$app_dir/Contents/MacOS/InformationBar" 2>/dev/null
mv "$app_dir/Contents/MacOS/InformationBar.stamped" "$app_dir/Contents/MacOS/InformationBar"
cp scripts/collect.py "$app_dir/Contents/Resources/collect.py"
mkdir -p "$app_dir/Contents/Resources/Providers"
cp assets/providers/*.svg "$app_dir/Contents/Resources/Providers/"
cp assets/providers/README.md "$app_dir/Contents/Resources/Providers/"
cp assets/providers/LICENSE-*.txt "$app_dir/Contents/Resources/Providers/"
# App icon: an Icon Composer package compiled by the asset compiler, so macOS renders the
# Default, Dark, Clear and Tinted styles itself. Produces Assets.car and an .icns fallback.
icon_build="$(mktemp -d)"
xcrun actool --output-format human-readable-text --warnings --errors \
  --output-partial-info-plist "$icon_build/icon.plist" \
  --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
  --development-region en --target-device mac --minimum-deployment-target 27.0 \
  --platform macosx --compile "$app_dir/Contents/Resources" assets/app-icon/AppIcon.icon \
  | grep -vE '^/\*|^$|Assets\.car$|AppIcon\.icns$|icon\.plist$' || true
rm -rf "$icon_build"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.starecat.InformationBar</string>
  <key>CFBundleName</key><string>Information Bar</string>
  <key>CFBundleDisplayName</key><string>Information Bar</string>
  <key>CFBundleExecutable</key><string>InformationBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
