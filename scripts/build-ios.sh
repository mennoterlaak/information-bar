#!/bin/bash
# Generate and build the native iPhone/iPad app and its WidgetKit extension.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
ios_dir="$project_dir/ios"
platform="simulator"
action="build"
destination=""

usage() {
  cat <<'HELP'
Usage: scripts/build-ios.sh [simulator|device] [--test] [--destination DESTINATION]

simulator   Build with local ad-hoc signing and shared entitlements (default).
device      Build for iPhone/iPad with automatic development signing.
--test      Run tests; requires an explicit --destination for a bootable simulator.

Examples:
  scripts/build-ios.sh simulator
  scripts/build-ios.sh simulator --test --destination 'platform=iOS Simulator,id=UUID'
  scripts/build-ios.sh device

Requires Xcode and XcodeGen. Device signing uses the team's existing Xcode account.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    simulator|device) platform="$1"; shift ;;
    --test) action="test"; shift ;;
    --destination)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      destination="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v xcodegen >/dev/null || { printf 'Install XcodeGen before building.\n' >&2; exit 1; }
xcodebuild -version >/dev/null
if [[ "$action" == "test" && ( "$platform" != "simulator" || -z "$destination" ) ]]; then
  printf 'Tests require simulator mode and --destination with a simulator name or ID.\n' >&2
  exit 2
fi

build_dir="$ios_dir/.build/$platform"
log_dir="$ios_dir/.build/logs"
mkdir -p "$log_dir"
log_file="$log_dir/$platform-$action.log"
xcodegen generate --spec "$ios_dir/project.yml" --project "$ios_dir" --quiet

arguments=(
  -project "$ios_dir/InformationBarMobile.xcodeproj"
  -scheme InformationBarMobile
  -configuration Debug
  -derivedDataPath "$build_dir"
  -quiet
)
if [[ "$platform" == "simulator" ]]; then
  # Xcode must process simulator signing to resolve AppIdentifierPrefix and embed
  # the App Group/Keychain entitlements. No Apple signing identity is required.
  arguments+=(-destination "${destination:-generic/platform=iOS Simulator}"
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-)
else
  arguments+=(-destination "${destination:-generic/platform=iOS}" -allowProvisioningUpdates -allowProvisioningDeviceRegistration)
fi

printf 'Building Information Bar for %s…\n' "$platform"
if xcodebuild "${arguments[@]}" "$action" >"$log_file" 2>&1; then
  sdk="iphonesimulator"
  [[ "$platform" == "device" ]] && sdk="iphoneos"
  printf 'Built: %s\n' "$build_dir/Build/Products/Debug-$sdk/InformationBarMobile.app"
  [[ "$action" == "test" ]] && printf 'iOS tests passed.\n'
  printf 'Build log: %s\n' "$log_file"
else
  result=$?
  printf 'iOS %s failed (exit %s). Last diagnostics:\n' "$action" "$result" >&2
  tail -n 60 "$log_file" >&2
  printf 'Full log: %s\n' "$log_file" >&2
  exit "$result"
fi
