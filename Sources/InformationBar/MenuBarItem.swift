import SwiftUI

/// The composed content of one status item; the Settings preview renders the same view.
struct MenuBarItemView: View {
  let provider: Provider
  let options: ProviderPreferences

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
      // A little extra room between the icon and whatever follows it.
      ProviderIcon(id: provider.id, size: 16).padding(.trailing, 4)
    case .ring:
      let percent =
        provider.id == "vast"
        ? provider.utilizationAverage.map { $0 * 100 }
        : provider.pool(element.windowID)?.usedPercent
      MenuRingGlyph(percent: provider.isFresh ? percent : nil)
    case .earningsGraph:
      MenuBarsGlyph(values: provider.isFresh ? (provider.daily ?? []).map(\.amount) : [])
    default:
      Text(provider.text(for: element, preferences: options) ?? "—")
        .font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
    }
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
