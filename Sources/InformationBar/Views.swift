import SwiftUI

extension Color {
  /// Brand colours. OpenAI and Cursor publish monochrome marks, so their tiles are black with a
  /// white mark, like their app icons; Claude is terracotta (#D97757) and Vast.ai blue (#315FFF).
  static let codex = Color.black
  static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
  static let cursor = Color(red: 0.149, green: 0.145, blue: 0.118)
  static let vast = Color(red: 0.192, green: 0.373, blue: 1.0)
  /// Status green for connected, live and rented states.
  static let live = Color(red: 0.13, green: 0.57, blue: 0.44)

  /// Tile colour for a provider.
  static func provider(_ id: String) -> Color {
    switch id {
    case "codex": return .codex
    case "claude": return .claude
    case "cursor": return .cursor
    default: return .vast
    }
  }

  /// Colour for a provider's mark or gauge on a neutral surface; monochrome brands follow the
  /// label colour so they stay visible in both appearances.
  static func mark(_ id: String) -> Color {
    isMonochrome(id) ? .primary : provider(id)
  }

  static func isMonochrome(_ id: String) -> Bool { id == "codex" || id == "cursor" }

  /// Brands whose Default-style app icon is a flat white tile with a black mark, as ChatGPT in
  /// the Dock. Their tile only turns black under the Dark icon style.
  static func hasLightTile(_ id: String) -> Bool { id == "codex" }
}

/// Small coloured status label used in the Settings connection section.
struct StatePill: View {
  let text: String
  let color: Color
  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(text).font(.system(size: 10, weight: .medium))
    }
    .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4)
    .background(color.opacity(0.09), in: Capsule())
  }
}
