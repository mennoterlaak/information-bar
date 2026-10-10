import SwiftUI

struct KrakenSettingsSections: View {
  @ObservedObject var store: DashboardStore
  @State private var apiKey = ""
  @State private var privateKey = ""
  private var provider: Provider { store.providers["kraken"] ?? .placeholder("kraken") }
  private var currency: Binding<String> {
    Binding(
      get: { store.preferences.provider(.kraken).currency },
      set: { value in store.update(.kraken) { $0.currency = value } })
  }

  var body: some View {
    Section {
      Picker("Currency", selection: currency) {
        Text("US dollar").tag("USD")
        Text("Euro").tag("EUR")
      }
    } header: {
      sectionHeader(
        "Portfolio",
        info:
          "Each asset is valued at the last trade on its Kraken market in this currency. Assets without one are converted through their USD, EUR, BTC, ETH, USDT or USDC market. Staked and Earn balances count toward their asset; fee credits are left out."
      )
    }
    Section {
      LabeledContent("Kraken account") {
        StatePill(
          text: provider.isFresh
            ? "Connected" : store.krakenConnected ? "Key saved" : "Not connected",
          color: provider.isFresh ? .live : .orange)
      }
      SecureField(store.krakenConnected ? "Replace API key" : "API key", text: $apiKey)
      SecureField("Private key", text: $privateKey).onSubmit(save)
      Text(
        "Create a separate key with only the Query Funds permission. Information Bar reads balances and cannot trade or withdraw with it."
      )
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Link(
          "Create an API key", destination: URL(string: "https://pro.kraken.com/app/settings/api")!)
        Spacer()
        if store.validatingKraken { ProgressView().controlSize(.small) }
        if store.krakenConnected {
          Button("Disconnect", role: .destructive, action: store.disconnectKraken)
            .disabled(store.validatingKraken)
        }
        Button("Save & connect", action: save).buttonStyle(.borderedProminent)
          .disabled(apiKey.isEmpty || privateKey.isEmpty || store.validatingKraken)
      }
      if let message = store.krakenMessage {
        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
      }
      if let error = store.collectorErrors["kraken"]
        ?? (store.krakenConnected ? provider.error : nil)
      {
        Text(error).font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      sectionHeader(
        "Connection",
        info:
          "Both keys are stored in macOS Keychain and passed to the collector privately. The API key is sent only to api.kraken.com; the private key never leaves this Mac and only signs requests. Neither is written to the cache."
      )
    }
  }

  private func save() {
    Task {
      if await store.saveKraken(apiKey: apiKey, privateKey: privateKey) {
        apiKey = ""
        privateKey = ""
      }
    }
  }
}
