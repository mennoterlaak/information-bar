import SwiftUI

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

/// Green for gains and red for losses, as in Stocks; no change stays neutral.
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
        // With positions open the total adds two parts, so each gets its own heading.
        if kraken.openMargin != nil {
          MenuSectionLabel(title: "Balances", trailing: money.local(kraken.totalValue))
        }
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
        if let margin = kraken.openMargin {
          MenuSeparator()
          KrakenMarginSection(margin: margin, money: money)
        } else if let error = kraken.margin?.error {
          menuNote(error)
        }
      }
    }
    .opacity(provider.isFresh ? 1 : 0.55)
  }
}

/// Open margin positions, then what they do to the account.
struct KrakenMarginSection: View {
  let margin: KrakenMargin
  let money: MoneyFormat
  private var positions: [KrakenPosition] { margin.positions ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MenuSectionLabel(
        title: "Margin",
        trailing: "\(positions.count) " + (positions.count == 1 ? "position" : "positions"))
      ForEach(positions) { KrakenPositionRow(position: $0, money: money) }
      let pnl = margin.unrealizedNow.map { formatSigned($0, money: money) }
      MenuValueRow(title: "Unrealized P&L", value: pnl ?? "—", tint: pnl.map(signColor) ?? .primary)
        .help(
          "Profit or loss if every position closed at the last trade, before closing fees. The total at the top includes it."
        )
      MenuValueRow(title: "Equity", value: money.local(margin.equityNow)).help(equityHelp)
      MenuValueRow(
        title: "Used margin", value: money.local(margin.used),
        detail: margin.freeNow.map { money.local($0) + " free" }
      )
      .help(
        "Initial margin held by the open positions. Free margin is equity minus used margin: what is left to open new positions."
      )
      MenuValueRow(
        title: "Margin level", value: margin.levelNow.map(formatMarginLevel) ?? "—",
        tint: riskColor(margin.risk) ?? .primary
      )
      .help(levelHelp)
      if let rollover = margin.rolloverPerDay {
        MenuValueRow(title: "Rollover fees", value: "≈ " + money.local(rollover) + "/day")
          .help(
            "Estimated from each position's rollover rate, which Kraken charges every 4 hours on what it lends: the cost of a long, the amount of a short."
          )
      }
    }
  }

  private var equityHelp: String {
    let collateral = margin.tradeBalance.map { "Collateral of " + money.local($0) } ?? "Collateral"
    return collateral
      + " plus unrealized P&L. Collateral counts the balances Kraken accepts for margin."
  }

  private var levelHelp: String {
    var text = "Equity as a percentage of used margin."
    if let call = margin.marginCall, let stop = margin.liquidation {
      text += String(
        format: " Kraken calls margin at %.0f%% and liquidates positions at %.0f%%.", call, stop)
    }
    if let cushion = margin.cushionNow, cushion > 0 {
      text += " Equity can fall by " + money.local(cushion) + " before liquidation."
    }
    return text
  }
}

/// Red from the margin call level, orange once no free margin is left; nil otherwise.
func riskColor(_ risk: KrakenMargin.Risk) -> Color? {
  switch risk {
  case .marginCall: return .red
  case .noFreeMargin: return .orange
  case .normal: return nil
  }
}

/// Green for a gain and red for a loss, read from the sign of a formatted amount.
func signColor(_ text: String) -> Color {
  text.hasPrefix("+") ? .green : text.hasPrefix("-") ? .red : .secondary
}

struct KrakenPositionRow: View {
  let position: KrakenPosition
  let money: MoneyFormat

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(position.symbol).font(.system(size: 13, weight: .medium))
        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        let pnl = position.pnl.map { formatSigned($0, money: money) }
        Text(pnl ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
          .foregroundStyle(pnl.map(signColor) ?? .primary)
        Text(move).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .padding(.horizontal, MenuMetrics.inset).padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .help(tooltip)
  }

  /// "$79,000 → $82,938"
  private var move: String {
    formatQuoteMove(from: position.entryPrice, to: position.currentPrice, quote: position.quote)
  }

  /// "Long 5× · 0.15 BTC"
  private var summary: String {
    var side = position.isLong ? "Long" : "Short"
    if let leverage = position.leverage { side += " " + formatLeverage(leverage) }
    return side + " · " + formatQuantity(position.amount, decimals: position.decimals) + " "
      + position.base
  }

  private var tooltip: String {
    let quote = position.quote
    var lines = [
      (position.isLong ? "Long " : "Short ")
        + formatQuantity(position.amount, decimals: 10) + " " + position.base + " on Kraken "
        + position.symbol
        + (position.leverage.map { " at " + formatLeverage($0) + " leverage" } ?? "")
    ]
    var prices =
      "Entry " + formatQuotePrice(position.entryPrice, quote: quote) + " · last trade "
      + formatQuotePrice(position.currentPrice, quote: quote)
    if let change = position.marketChange { prices += " (" + formatChange(change) + " today)" }
    lines.append(prices)
    if let net = position.netNow {
      var line = "Unrealized P&L " + formatQuoteAmount(net, quote: quote, signed: true)
      if let margin = position.margin, margin > 0 {
        line +=
          String(format: ", %.1f%% of the ", net / margin * 100)
          + formatQuoteAmount(margin, quote: quote) + " margin"
      }
      lines.append(line)
    }
    if let cost = position.cost {
      lines.append(
        "Opening cost " + formatQuoteAmount(cost, quote: quote)
          + (position.fee.map { " · fees " + formatQuoteAmount($0, quote: quote) } ?? ""))
    }
    if let terms = position.terms {
      var line = "Rollover " + terms
      if let next = position.nextRollover {
        line +=
          ", next at "
          + Date(timeIntervalSince1970: next).formatted(date: .omitted, time: .shortened)
      }
      lines.append(line)
    }
    if let opened = position.opened {
      let date = Date(timeIntervalSince1970: opened)
      var line = "Opened " + date.formatted(date: .abbreviated, time: .shortened)
      if let fills = position.fills, fills > 1 { line += " · \(fills) fills" }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}

/// Leverage as Kraken offers it, as in "5×" or "2.5×".
func formatLeverage(_ leverage: Double) -> String {
  String(format: "%g×", (leverage * 10).rounded() / 10)
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
