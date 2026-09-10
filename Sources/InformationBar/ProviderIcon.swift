import AppKit
import SwiftUI

@MainActor
enum ProviderArtwork {
  private static var originals: [String: NSImage] = [:]
  // Sized template copies are reused; views and status items request them on every update.
  private static var sized: [String: NSImage] = [:]

  static func image(_ id: String, size: CGFloat = 18) -> NSImage {
    let key = "\(id)@\(size)"
    if let cached = sized[key] { return cached }
    if originals[id] == nil,
      let url = AppInfo.resource("Providers/\(id).svg", development: "assets/providers/\(id).svg")
    {
      originals[id] = NSImage(contentsOf: url)
    }
    guard let original = originals[id], let image = original.copy() as? NSImage else {
      return NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: id)!
    }
    let ratio = image.size.width / max(1, image.size.height)
    image.size =
      ratio > 1
      ? NSSize(width: size, height: size / ratio) : NSSize(width: size * ratio, height: size)
    image.isTemplate = true
    image.accessibilityDescription = Provider.names[id] ?? id
    sized[key] = image
    return image
  }

  /// The mark filled with `tint`, for contexts that draw images verbatim, such as Canvas.
  static func image(_ id: String, size: CGFloat, tint: NSColor) -> NSImage {
    let key = "\(id)@\(size)#\(tint.description)"
    if let cached = sized[key] { return cached }
    let base = image(id, size: size)
    let result = NSImage(size: base.size, flipped: false) { rect in
      base.draw(in: rect)
      tint.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    result.accessibilityDescription = base.accessibilityDescription
    sized[key] = result
    return result
  }
}

struct ProviderIcon: View {
  let id: String
  var size: CGFloat = 22
  var body: some View {
    Image(nsImage: ProviderArtwork.image(id, size: size))
      .renderingMode(.template).resizable().scaledToFit()
      .frame(width: size, height: size)
      .accessibilityLabel(Provider.names[id] ?? id)
  }
}
