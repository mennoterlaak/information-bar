import SwiftUI

enum MenuBarMetrics {
  /// Distance between the contents of two providers in one status item. Each provider's cell
  /// takes half of it on either side, which is also the room its highlight needs.
  static let gap: CGFloat = 12
  /// macOS pads every status item by 8pt per side and clips what is drawn beyond that. The
  /// outer half gaps are drawn into that padding, so the group sits as close to its
  /// neighbours as a single item would.
  static let overflow: CGFloat = 7
  /// Corner radius of the highlight behind the provider whose dropdown is open.
  static let highlightRadius: CGFloat = 6
}

/// One provider inside a status item.
struct MenuBarSegment: Identifiable {
  let category: ProviderCategory
  let provider: Provider
  /// Preferences whose elements are already trimmed to the form in use.
  let options: ProviderPreferences
  /// Measured width of the content, so the status item knows where each provider is. Nil
  /// lets the content take its natural width, as in the Settings preview.
  var width: CGFloat? = nil
  var id: ProviderCategory { category }
}

/// The providers of one status item side by side; the Settings preview renders the same view.
struct MenuBarStripView: View {
  let segments: [MenuBarSegment]
  var power = PowerContext.empty
  /// The provider whose dropdown is open.
  var active: ProviderCategory? = nil

  var body: some View {
    HStack(spacing: 0) {
      ForEach(segments) { segment in
        MenuBarItemView(provider: segment.provider, options: segment.options, power: power)
          .frame(width: segment.width)
          .padding(.horizontal, MenuBarMetrics.gap / 2)
          .frame(maxHeight: .infinity)
          .background {
            if active == segment.category {
              RoundedRectangle(cornerRadius: MenuBarMetrics.highlightRadius, style: .continuous)
                .fill(.primary.opacity(0.14)).padding(.horizontal, 1)
            }
          }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

/// The composed content of one provider; the Settings preview renders the same view.
struct MenuBarItemView: View {
  let provider: Provider
  let options: ProviderPreferences
  var power = PowerContext.empty

  var body: some View {
    HStack(spacing: 5) {
      ForEach(options.elements.isEmpty ? [MenuElement(.icon)] : options.elements) { element in
        elementView(element)
      }
    }
    .padding(.horizontal, 1)
    .fixedSize()
  }

  @ViewBuilder private func elementView(_ element: MenuElement) -> some View {
    switch element.kind {
    case .icon:
      // The icon sits closer to its own value than to the next provider.
      ProviderIcon(id: provider.id, size: 16).padding(.trailing, 1)
    case .ring:
      let percent =
        provider.id == "vast"
        ? provider.utilizationAverage.map { $0 * 100 }
        : provider.pool(element.windowID)?.usedPercent
      MenuRingGlyph(percent: provider.isFresh ? percent : nil)
    case .earningsGraph:
      MenuBarsGlyph(values: provider.isFresh ? (provider.daily ?? []).map(\.amount) : [])
    default:
      let text = Text(provider.text(for: element, preferences: options, power: power) ?? "—")
        .font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
      if let alert = alert(element) { text.foregroundStyle(alert) } else { text }
    }
  }

  /// A margin level close to Kraken's margin call stands out, as a ring does from 90%.
  private func alert(_ element: MenuElement) -> Color? {
    guard element.kind == .marginLevel, provider.isFresh,
      let margin = provider.kraken?.openMargin
    else { return nil }
    return riskColor(margin.risk)
  }
}

/// Small ring for the menu bar: track plus fill, orange from 90%, empty while stale.
struct MenuRingGlyph: View {
  let percent: Double?
  var body: some View {
    ZStack {
      Circle().stroke(.primary.opacity(0.25), lineWidth: 2)
      if let percent {
        Circle().trim(from: 0, to: min(1, max(0, percent / 100)))
          .stroke(
            percent >= 90 ? Color.orange : Color.primary,
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      }
    }
    .frame(width: 13, height: 13).padding(1)
  }
}

/// Seven tiny bars scaled to the highest day; a flat line while there is no data.
struct MenuBarsGlyph: View {
  let values: [Double]
  var body: some View {
    let peak = max(values.max() ?? 0, 0.0001)
    HStack(alignment: .bottom, spacing: 1.5) {
      if values.isEmpty {
        RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.25)).frame(width: 20, height: 2)
      }
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.85))
          .frame(width: 2.5, height: max(1.5, 12 * value / peak))
      }
    }
    .frame(height: 12, alignment: .bottom)
  }
}
