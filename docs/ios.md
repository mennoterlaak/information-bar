# Information Bar for iPhone and iPad

The native SwiftUI app mirrors the Mac dashboard, with configurable WidgetKit widgets for the Home Screen and Lock Screen. It supports iOS/iPadOS 17 and later, including iPhone Air, with the system's light and dark appearance and Dynamic Type.

The Mac remains the source of the readings and provider settings. The phone receives normalized snapshots over an authenticated, certificate-pinned HTTPS connection on your local network. Provider account credentials stay on the Mac. The app and widgets share the latest snapshot through an App Group and the separate companion credential through Keychain.

## Build

Use Xcode 27 and XcodeGen. The source project definition is `ios/project.yml`; the build script regenerates the Xcode project before compiling.

```sh
scripts/build-ios.sh simulator
scripts/build-ios.sh device
```

The simulator build uses local ad-hoc signing so Xcode embeds the shared App Group and Keychain entitlements; it does not require an Apple signing identity. The device build uses automatic development signing with the existing team `K8MRZPASGA`, including provisioning updates and device registration. Xcode must already have access to the team's signing account. The app identifier is `dev.starecat.InformationBar.mobile` and the widget identifier is `dev.starecat.InformationBar.mobile.widgets`.

Outputs are in `ios/.build/simulator` and `ios/.build/device`; diagnostics are in `ios/.build/logs`. Open `ios/InformationBarMobile.xcodeproj` to run or debug in Xcode.

To run the iOS unit tests, select an installed simulator ID from `xcrun simctl list devices available`:

```sh
scripts/build-ios.sh simulator --test \
  --destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID'
```

Launch the app with `--demo` for explicitly synthetic preview data. A normal unpaired launch starts with the connection screen; demo readings are never used as a live-data fallback.

## Connect the Mac

Keep the Mac Information Bar app running so its collector updates the provider caches. Install the companion once:

```sh
scripts/install-mobile-bridge.sh
```

This creates a private TLS identity and connection file, installs a per-user LaunchAgent, and starts the HTTPS companion on port `8943`. It defaults to the Mac's `.local` hostname. Override it if necessary with `--host your-mac.local`; `--port` changes the listener and the saved connection endpoint together. Allow local-network access when macOS or iOS asks.

The companion runs while the Mac is awake and your user session is active. Both devices need a route to the Mac on the same local network. Sleeping the Mac, changing networks, or disabling the collector stops fresh readings from reaching the phone.

Check connection metadata without printing account data or pairing secrets:

```sh
python3 scripts/mobile_bridge.py --status
```

For foreground debugging without installing the LaunchAgent:

```sh
python3 scripts/mobile_bridge.py --setup
python3 scripts/mobile_bridge.py --serve
```

The private connection file lives at `~/Library/Application Support/Information Bar/Mobile/pairing.local.json`. Import it with **Open connection file** in the iOS connection screen, then confirm **Connect**. The file grants read access to your dashboard, so keep it private. Account keys and provider authentication material are not included.

## Install wirelessly on iPhone

The installer targets the iPhone paired with this Mac. With more than one paired iPhone, or to install on an iPad, add `--device` with a UDID from `xcrun devicectl list devices`. Unlock the phone on the same Wi-Fi as the Mac, with Developer Mode enabled and Xcode's wireless device connection available, then run:

```sh
scripts/install-ios.sh --pair
```

The script checks device reachability, builds a signed app, installs it through CoreDevice, launches it, and optionally delivers the Mac connection settings through the existing trusted device connection. Use `--skip-build` to install an already built device app. If the phone is unavailable, the script stops and says that installation did not run. A successful build alone does not mean the app is installed or connected.

To pair an app that is already installed:

```sh
python3 scripts/mobile_bridge.py \
  --pair-device YOUR_DEVICE_UDID \
  --bundle-id dev.starecat.InformationBar.mobile
```

This is a development installation over the Mac's paired-device transport. It requires the phone to be reachable; it is not an App Store or TestFlight release and cannot deliver a build to an offline phone. Development signing and device trust must remain valid for the installed app to launch.

## Widgets and freshness

Open the app and connect once, then add Information Bar from the system widget gallery. Widget configurations select the provider to display. The app and widgets use the same saved provider settings, currencies, power assignments, and source timestamps.

Opening the app refreshes its snapshot and requests widget reloads. WidgetKit controls background execution and may delay a requested update; there is no guaranteed per-minute refresh on the Home Screen or Lock Screen. See Apple's [widget update guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

When the Mac cannot be reached, the last valid snapshot remains visible with its original source age. Downloading a snapshot does not make old provider data fresh. Stale power-dependent projections become unavailable instead of assuming a zero electricity cost. Use the visible source age to distinguish a current reading from a cached one.

## Stop the companion

```sh
launchctl bootout "gui/$(id -u)/dev.starecat.InformationBar.mobile-bridge"
```

This stops the current service. Remove `~/Library/LaunchAgents/dev.starecat.InformationBar.mobile-bridge.plist` to prevent it from starting again at login. Disconnect in the iOS app to remove that device's saved connection and cached snapshot. Keep the private identity directory if you plan to resume using the same pairing.
