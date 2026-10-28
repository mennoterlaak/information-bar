#!/bin/bash
# Install onto the iPhone paired with this Mac, or the device given with --device. CoreDevice supports wireless transport.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
device_id=""
bundle_id="dev.starecat.InformationBar.mobile"
app_path="$project_dir/ios/.build/device/Build/Products/Debug-iphoneos/InformationBarMobile.app"
build_first=true
pair_after=false

usage() {
  cat <<'HELP'
Usage: scripts/install-ios.sh [--device UDID] [--skip-build] [--pair]

Build, install, and launch Information Bar on the iPhone paired with this Mac.
The device must be reachable, unlocked, trusted, and have Developer Mode enabled.
Wireless installation uses CoreDevice's existing device pairing.

--device UDID  Install on this device, as listed by `xcrun devicectl list devices`.
               Needed with more than one paired iPhone, or for an iPad.
--skip-build   Install the existing signed device build.
--pair         After installation, use the configured Mac bridge to pair the app.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      device_id="$2"; shift 2 ;;
    --skip-build) build_first=false; shift ;;
    --pair) pair_after=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

device_info="$(mktemp -t informationbar-device)"
selection="$(mktemp -t informationbar-selection)"
trap 'rm -f "$device_info" "$selection"' EXIT
if ! xcrun devicectl list devices --quiet --timeout 20 --json-output "$device_info"; then
  printf 'Could not list the devices paired with this Mac. Installation did not run.\n' >&2
  exit 1
fi

# Writes the chosen device's UDID and name; a refusal stops the script with its reason.
python3 - "$device_info" "$device_id" >"$selection" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
target = sys.argv[2]


def hardware(item, key):
    return item.get("properties", {}).get("hardware", {}).get(key) or item.get("hardwareProperties", {}).get(key)


if target:
    device = next((item for item in devices if hardware(item, "udid") == target), None)
    if device is None:
        sys.exit("No device with UDID " + target + " is paired with this Mac. Installation did not run.")
else:
    phones = [item for item in devices
              if hardware(item, "deviceType") == "iPhone" and hardware(item, "reality") != "simulated"]
    if not phones:
        sys.exit("No iPhone is paired with this Mac. Pass --device UDID for another device. Installation did not run.")
    if len(phones) > 1:
        sys.exit("More than one iPhone is paired with this Mac. Pass --device UDID to choose one. Installation did not run.")
    device = phones[0]
properties = device.get("properties", {})
name = properties.get("state", {}).get("name") or device.get("deviceProperties", {}).get("name") or "The device"
connection = properties.get("connection", {})
legacy_connection = device.get("connectionProperties", {})
state = connection.get("state", legacy_connection.get("tunnelState", "unknown"))
pairing = connection.get("pairingState", legacy_connection.get("pairingState", "unknown"))
if pairing != "paired":
    sys.exit(name + " is not currently paired. Installation did not run.")
if state in ("unavailable", "disconnected", "unknown"):
    sys.exit(name + " is unavailable. Unlock it on the same Wi-Fi as this Mac and retry. Installation did not run.")
mode = properties.get("state", {}).get("developerModeStatus")
legacy_mode = device.get("deviceProperties", {}).get("developerModeStatus")
if (isinstance(mode, dict) and "disabled" in mode) or legacy_mode == "disabled":
    sys.exit("Enable Developer Mode on " + name + " before installation. Installation did not run.")
print(name + " is paired and reachable.", file=sys.stderr)
print(hardware(device, "udid"))
print(name)
PY
{ read -r device_id; read -r device_name; } <"$selection"

if [[ "$build_first" == true ]]; then
  bash "$project_dir/scripts/build-ios.sh" device
fi
[[ -d "$app_path" ]] || { printf 'Device build not found: %s\n' "$app_path" >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
[[ "$actual_bundle_id" == "$bundle_id" ]] || { printf 'Unexpected app bundle identifier. Installation stopped.\n' >&2; exit 1; }

printf 'Installing Information Bar on %s…\n' "$device_name"
xcrun devicectl device install app --device "$device_id" "$app_path" --quiet --timeout 60
printf 'Installed on %s. Launching…\n' "$device_name"
xcrun devicectl device process launch --device "$device_id" --quiet --timeout 30 "$bundle_id"
printf 'Information Bar launched on %s.\n' "$device_name"

if [[ "$pair_after" == true ]]; then
  python3 "$project_dir/scripts/mobile_bridge.py" --pair-device "$device_id" --bundle-id "$bundle_id"
fi
