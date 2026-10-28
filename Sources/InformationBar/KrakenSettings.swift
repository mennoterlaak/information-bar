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
  private var livePrices: Binding<Bool> {
    Binding(
      get: { store.preferences.provider(.kraken).livePrices },
      set: { value in store.update(.kraken) { $0.livePrices = value } })
  }
  private var marginPositions: Binding<Bool> {
    Binding(
      get: { store.preferences.provider(.kraken).marginPositions },
      set: { value in store.update(.kraken) { $0.marginPositions = value } })
  }

  var body: some View {
    Section {
      Picker("Currency", selection: currency) {
        Text("US dollar").tag("USD")
        Text("Euro").tag("EUR")
      }
      Toggle(isOn: livePrices) {
        Text("Live prices")
        Text(liveStatus)
      }
      Toggle(isOn: marginPositions) {
        Text("Margin positions")
        Text(marginStatus)
      }
    } header: {
      sectionHeader(
        "Portfolio",
        info:
          "Each asset is valued at the last trade on its Kraken market in this currency. Assets without one are converted through their USD, EUR, BTC, ETH, USDT or USDC market. Staked and Earn balances count toward their asset; fee credits are left out. Open margin positions add their unrealized profit or loss to the total and today's change; the dropdown lists them with equity, used margin and margin level. Live prices follow every trade on those markets through Kraken's public feed, without your keys, while the Mac and its display are awake. The menu bar redraws at most once a second; balances still refresh every minute."
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
        "Create a separate key with the Query Funds permission, and Query Open Orders & Trades for margin positions. Information Bar only reads with it and cannot trade or withdraw."
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

  private var liveStatus: String {
    let options = store.preferences.provider(.kraken)
    guard options.livePrices else { return "Prices update with the balances every minute." }
    switch store.krakenFeed {
    case .off:
      if !options.enabled { return "Starts when Kraken is shown in the menu bar." }
      if !store.krakenConnected { return "Starts once your Kraken account is connected." }
      if provider.isFresh && provider.kraken?.liveSymbols.isEmpty == true {
        return "None of these holdings has a Kraken market to follow."
      }
      return "Starts once the portfolio has loaded."
    case .connecting: return "Connecting to Kraken…"
    case .live(let markets):
      return "Following \(markets) " + (markets == 1 ? "market" : "markets") + " as they trade."
    case .retrying(let next):
      return "Connection lost. Trying again at "
        + next.formatted(date: .omitted, time: .standard) + "."
    case .paused: return "Paused while the display is asleep."
    }
  }

  private var marginStatus: String {
    guard store.preferences.provider(.kraken).marginPositions else {
      return "Only spot balances are read."
    }
    guard provider.isFresh, let kraken = provider.kraken else {
      return "Read with the balances. Needs the Query Open Orders & Trades permission."
    }
    guard let margin = kraken.margin else { return "Not available right now." }
    if let error = margin.error { return error }
    guard let open = kraken.openMargin, let count = open.positions?.count else {
      return "No open positions."
    }
    return "\(count) open " + (count == 1 ? "position" : "positions")
      + (open.levelNow.map { " · margin level " + formatMarginLevel($0) } ?? "") + "."
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
