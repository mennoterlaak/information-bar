import SwiftUI

struct PearlSettingsSections: View {
  @ObservedObject var store: DashboardStore
  @State private var draft = PearlPreferences()
  @State private var message: String?
  private var provider: Provider { store.providers["pearl"] ?? .placeholder("pearl") }

  var body: some View {
    Section("Kryptex pool") {
      TextField(
        "PRL wallet address", text: $draft.walletAddress, prompt: Text("prl1…"))
      TextField("Worker", text: $draft.workerName, prompt: Text("All workers"))
      Text("Reads your accepted hashrate directly from Kryptex. Leave Worker empty to include all workers for this wallet.")
        .font(.callout).foregroundStyle(.secondary)
      if provider.isFresh, let hashrate = provider.pearl?.hashrate {
        LabeledContent("Pool hashrate · 30m", value: formatHashrate(hashrate))
      }
      if let error = message ?? store.collectorErrors["pearl"] ?? provider.error {
        Text(error).font(.callout).foregroundStyle(.orange).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        Text(provider.ageLabel).foregroundStyle(.secondary)
        Spacer()
        Button("Save & connect") {
          draft.walletAddress = draft.walletAddress.trimmingCharacters(in: .whitespacesAndNewlines)
          draft.workerName = draft.workerName.trimmingCharacters(in: .whitespacesAndNewlines)
          if let error = draft.validationError {
            message = error
            return
          }
          store.updatePearl { $0 = draft }
          message = nil
        }.buttonStyle(.borderedProminent)
      }
    }
    .onAppear {
      draft = store.preferences.pearl
    }
    Section("Wallet & payouts") {
      Text("Wallet balance shows confirmed PRL at the saved mining address from Pearl's public explorer. Unpaid rewards and payout history come from Kryptex and cover the whole wallet, even when a single worker is selected.")
        .font(.callout).foregroundStyle(.secondary)
      Text("Use Add item above to show Wallet balance, Unpaid pool rewards or Total paid by pool in the menu bar.")
        .font(.caption).foregroundStyle(.secondary)
    }
    Section("Profit projections") {
      Text(
        "Hourly, daily, weekly and 30-day monthly estimates use the pool's 30-minute hashrate, PRL price and Kryptex PPS+ yield after the pool fee. Accepted hashrate already reflects time spent mining developer fees. Profit also deducts the electricity assigned to Pearl in Power Settings."
      )
      .font(.callout).foregroundStyle(.secondary)
      Text(
        "Assumes continuous mining at the current rate. Hardware, taxes, exchange and payout costs are excluded."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct PowerSettingsSections: View {
  @ObservedObject var store: DashboardStore
  @State private var editing: HomeWizardDevice?
  @StateObject private var discovery = HomeWizardDiscovery()
  private var power: PowerPreferences { store.preferences.power }

  private func binding<T>(_ path: WritableKeyPath<PowerPreferences, T>) -> Binding<T> {
    Binding(
      get: { power[keyPath: path] },
      set: { value in store.updatePower { $0[keyPath: path] = value } })
  }

  var body: some View {
    Section("Electricity tariff") {
      Picker("Tariff currency", selection: binding(\.currency)) {
        Text("US dollar").tag("USD")
        Text("Euro").tag("EUR")
      }
      DecimalField(
        title: "Price per kWh", value: binding(\.pricePerKWh), prompt: "Not set",
        suffix: power.currency, minimumDigits: 2)
      Text("Shared by Pearl and Vast.ai. Revenue currency can be changed independently.")
        .font(.caption).foregroundStyle(.secondary)
    }
    Section {
      ForEach(power.devices) { device in
        HStack(spacing: 10) {
          Image(systemName: "powerplug").foregroundStyle(Color.provider("power"))
          VStack(alignment: .leading, spacing: 3) {
            Text(device.name)
            Text(device.assignment.title).font(.caption).foregroundStyle(.secondary)
            if let error = store.powerContext.reading(device.id)?.error {
              Text(error).font(.caption).foregroundStyle(.orange)
            }
          }
          Spacer()
          Text(
            store.powerContext.reading(device.id)?.currentWatts.map { String(format: "%.0f W", $0) }
              ?? "—"
          )
          .monospacedDigit().foregroundStyle(.secondary)
          Button("Edit") { editing = device }
        }
      }
      HStack {
        Button(
          discovery.isSearching ? "Stop search" : "Search for devices",
          systemImage: discovery.isSearching ? "stop.circle" : "magnifyingglass"
        ) {
          if discovery.isSearching { discovery.stop() } else { discovery.start(demo: store.demo) }
        }
        Spacer()
        Button("Add by address…", systemImage: "plus") { editing = HomeWizardDevice() }
          .disabled(power.devices.count >= 32)
      }
      Picker(
        "Power item reads",
        selection: Binding(
          get: { power.displayDeviceID ?? "assigned" },
          set: { value in
            store.updatePower { $0.displayDeviceID = value == "assigned" ? nil : value }
          })
      ) {
        Text("Assigned loads").tag("assigned")
        ForEach(power.devices) { Text($0.name).tag($0.id) }
      }
      Button("Refresh meters") { store.refresh(force: true, only: "power") }
        .disabled(store.refreshing.contains("power"))
      if let error = store.collectorErrors["power"] {
        Text(error).font(.callout).foregroundStyle(.orange)
      }
    } header: {
      sectionHeader(
        "HomeWizard meters",
        info:
          "Assign a meter to Pearl or Vast.ai to use its measured draw for costs. All assigned meters must be available to calculate profit. Monitor-only meters, such as a whole-house P1 meter, are excluded from profit calculations and Assigned loads. Use separate, non-overlapping meters."
      )
    }
    .sheet(item: $editing) { device in HomeWizardEditor(store: store, initial: device) }
    .onDisappear { discovery.stop() }
    if discovery.hasSearched {
      Section("Search results") {
        if discovery.isSearching {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Searching your local network…").foregroundStyle(.secondary)
          }
        } else {
          Text(discovery.devices.isEmpty ? "No devices found." : "Search complete.")
            .foregroundStyle(.secondary)
        }
        ForEach(discovery.devices) { found in
          HStack(spacing: 10) {
            Image(systemName: "powerplug").foregroundStyle(Color.provider("power"))
            VStack(alignment: .leading, spacing: 3) {
              Text(found.device.name + " · " + found.device.serial.suffix(6))
              Text(found.device.address).font(.caption).foregroundStyle(.secondary)
              Text(found.setupHint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if found.isConfigured(in: power) {
              Label("Added", systemImage: "checkmark").foregroundStyle(.secondary)
            } else {
              Button("Set up…") { editing = found.device }
                .disabled(!found.measuresPower || power.devices.count >= 32)
            }
          }
        }
        if let error = discovery.error {
          Text(error).font(.callout).foregroundStyle(.orange)
        }
        Text(
          "Connect to the same network as your meters and allow Information Bar under System Settings → Privacy & Security → Local Network. Devices on another network can be added by address."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct HomeWizardEditor: View {
  @ObservedObject var store: DashboardStore
  @Environment(\.dismiss) private var dismiss
  @State private var device: HomeWizardDevice
  @State private var token = ""
  @State private var error: String?

  init(store: DashboardStore, initial: HomeWizardDevice) {
    self.store = store
    _device = State(initialValue: initial)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("HomeWizard meter") {
          TextField("Name", text: $device.name)
          TextField("Device address", text: $device.address, prompt: Text("192.168.1.18"))
          Picker("Local API", selection: $device.apiVersion) {
            Text("v1 · HTTP").tag("v1")
            Text("v2 · HTTPS with token").tag("v2")
          }
          .onChange(of: device.apiVersion) { _, version in
            if var address = URLComponents(string: device.address), address.scheme != nil {
              address.scheme = version == "v2" ? "https" : "http"
              if let port = address.port, [80, 443].contains(port) { address.port = nil }
              device.address = address.string ?? device.address
            }
          }
          Picker("Use power for", selection: $device.assignment) {
            ForEach(PowerAssignment.allCases, id: \.self) { Text($0.title).tag($0) }
          }
        }
        if device.apiVersion == "v2" {
          Section("Secure connection") {
            Picker("Device type", selection: $device.productType) {
              Text("P1 Meter").tag("p1dongle")
              Text("kWh Meter").tag("energymeter")
              Text("Energy Socket").tag("energysocket")
              Text("Plug-In Battery").tag("battery")
              if !["p1dongle", "energymeter", "energysocket", "battery"].contains(
                device.productType)
              {
                Text(device.productType).tag(device.productType)
              }
            }
            TextField("Serial number", text: $device.serial)
            SecureField("API token", text: $token)
            Text("Required for v2. Leave blank only if this meter already has a saved token.")
              .font(.caption).foregroundStyle(.secondary)
            Text(
              "The token is stored in macOS Keychain. Device type and serial number verify the secure connection."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Text(
            "Enable Local API in the HomeWizard app under Settings → Meters → Your meter. Energy Sockets use v1."
          )
          .font(.callout).foregroundStyle(.secondary)
        }
        Link(
          "HomeWizard API setup",
          destination: URL(
            string: "https://api-documentation.homewizard.com/docs/getting-started/")!)
      }.formStyle(.grouped)
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        if let error {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("homewizard-save-error")
        }
        HStack {
          if store.preferences.power.devices.contains(where: { $0.id == device.id }) {
            Button("Remove meter", role: .destructive) {
              store.removeDevice(device)
              dismiss()
            }
          }
          Spacer()
          Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          Button("Save meter") {
            do {
              device.address = device.address.trimmingCharacters(in: .whitespacesAndNewlines)
              device.serial = device.serial.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
              try store.saveDevice(device, token: token)
              token = ""
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("homewizard-save")
        }
      }.padding()
    }.frame(width: 550, height: device.apiVersion == "v2" ? 610 : 420)
  }
}
