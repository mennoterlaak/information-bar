import SwiftUI

/// Green for gains and red for losses, as in Stocks; no change stays neutral.
/// Marks prices that follow Kraken's trades as they happen.
struct LiveBadge: View {
  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(.green).frame(width: 6, height: 6)
      Text("Live").font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .help("Prices follow Kraken's trades as they happen. Balances refresh every minute.")
  }
}

func changeColor(_ fraction: Double) -> Color {
  formatChange(fraction) == formatChange(0) ? .secondary : fraction > 0 ? .green : .red
}

struct KrakenMenu: View {
  let provider: Provider
  private var kraken: KrakenMetrics? { provider.kraken }
  private var money: MoneyFormat { kraken?.money ?? MoneyFormat(currency: "USD", rates: nil) }
  /// Unpriced holdings stay listed so nothing disappears silently.
  private var listed: [KrakenAsset] { (kraken?.assets ?? []).filter { ($0.value ?? 1) >= 1 } }
  private var small: [KrakenAsset] { (kraken?.assets ?? []).filter { ($0.value ?? 1) < 1 } }
  private var unpriced: Int { (kraken?.assets ?? []).filter { $0.price == nil }.count }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let kraken {
        ForEach(listed) { asset in
          KrakenAssetRow(asset: asset, money: money, currency: kraken.currency, total: kraken.totalValue)
        }
        if !small.isEmpty {
          MenuValueRow(
            title: "Small balances", value: money.local(small.compactMap(\.value).reduce(0, +)),
            detail: "\(small.count) " + (small.count == 1 ? "asset" : "assets")
          )
          .help(
            small.map { formatQuantity($0.amount, decimals: $0.decimals) + " " + $0.symbol }
              .joined(separator: "\n"))
        }
        if kraken.assets.isEmpty { menuNote("No spot balances.") }
        if kraken.totalValue != nil && unpriced > 0 {
          menuNote(
            unpriced == 1
              ? "1 asset has no Kraken market and is left out of the total."
              : "\(unpriced) assets have no Kraken market and are left out of the total.")
        }
      }
    }
    .opacity(provider.isFresh ? 1 : 0.55)
  }
}

struct KrakenAssetRow: View {
  let asset: KrakenAsset
  let money: MoneyFormat
  let currency: String
  let total: Double?
  /// Cash in the portfolio currency has no price of its own.
  private var cash: Bool { asset.fiat && asset.symbol == currency }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(asset.symbol).font(.system(size: 13, weight: .medium))
        Text(holding).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(asset.value.map { money.local($0) } ?? "—")
          .font(.system(size: 13, weight: .semibold)).monospacedDigit()
        if !cash {
          HStack(spacing: 5) {
            Text(asset.price == nil ? "No price" : formatPrice(asset.price, money: money))
              .foregroundStyle(.secondary)
            if let change = asset.change {
              Text(formatChange(change)).foregroundStyle(changeColor(change))
            }
          }
          .font(.system(size: 11)).monospacedDigit()
        }
      }
    }
    .lineLimit(1)
    .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .help(tooltip)
  }

  private var amount: String {
    asset.fiat
      ? groupThousands(String(format: "%.2f", asset.amount))
      : formatQuantity(asset.amount, decimals: asset.decimals)
  }

  private var holding: String {
    if cash { return "Cash" }
    let text = amount + " " + asset.symbol
    guard asset.earn > 0 else { return text }
    if asset.earn >= asset.amount { return text + " in Earn" }
    return text + " · " + formatQuantity(asset.earn, decimals: asset.decimals) + " in Earn"
  }

  private var tooltip: String {
    var lines = [formatQuantity(asset.amount, decimals: 10) + " " + asset.symbol]
    if asset.earn > 0 {
      lines.append(formatQuantity(asset.earn, decimals: 10) + " staked or earning in Kraken Earn")
    }
    if let market = asset.market {
      lines.append("Last trade on Kraken " + market)
      if let open = asset.openPrice {
        lines.append("Opened today at " + formatPrice(open, money: money) + " (00:00 UTC)")
      }
    } else if asset.price == nil {
      lines.append("Kraken has no market to price this asset.")
    }
    if let value = asset.value, let total, total > 0 {
      lines.append(String(format: "%.1f%% of the portfolio", value / total * 100))
    }
    return lines.joined(separator: "\n")
  }
}
