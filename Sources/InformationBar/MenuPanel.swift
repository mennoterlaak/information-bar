import AppKit
import SwiftUI

/// Borderless floating panel under a status item, styled after the system's own menu bar
/// extras: glass background, rounded corners, no arrow, closes on outside clicks or Escape.
@MainActor
final class MenuPanel: NSPanel {
  static let cornerRadius: CGFloat = 16
  private let glass = NSGlassEffectView()
  /// Clips everything to the rounded shape so the window shadow follows it rather than the
  /// rectangular bounds, which otherwise shows as a thin dark outline.
  private let container = NSView()
  private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
  private var monitors: [Any] = []
  /// Windows whose clicks must not close the panel; the status items toggle it themselves.
  var ignoresClicks: (NSWindow?) -> Bool = { _ in false }
  var onDismiss: (() -> Void)?
  /// Left (-1) or right (1) arrow pressed while open.
  var onStep: ((Int) -> Void)?
  /// Called after the panel changes size while open; the QA flag logs it.
  var onRefit: ((NSSize) -> Void)?

  init() {
    glass.cornerRadius = Self.cornerRadius
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    animationBehavior = .utilityWindow
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    hosting.autoresizingMask = [.width, .height]
    glass.contentView = hosting
    container.wantsLayer = true
    container.layer?.cornerRadius = Self.cornerRadius
    container.layer?.masksToBounds = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    glass.autoresizingMask = [.width, .height]
    container.addSubview(glass)
    contentView = container
  }

  private func layoutContent() {
    glass.frame = container.bounds
    hosting.frame = glass.bounds
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Shows `content` under `anchor`, a rectangle in the menu bar in screen coordinates, sized
  /// to fit. Content taller than the screen scrolls.
  func present(
    under anchor: NSRect, on screen: NSScreen?, content: (_ maxHeight: CGFloat?) -> AnyView
  ) {
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? anchor
    let limit = visible.height - 16
    hosting.rootView = content(nil)
    var size = hosting.fittingSize
    if size.height > limit {
      hosting.rootView = content(limit)
      size = hosting.fittingSize
    }
    let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
    setFrame(
      NSRect(x: x, y: visible.maxY - 4 - size.height, width: size.width, height: size.height),
      display: true)
    layoutContent()
    makeKeyAndOrderFront(nil)
    invalidateShadow()
    installMonitors()
  }

  /// Re-measures after data changes while open, keeping the top edge under the menu bar.
  func refit() {
    guard isVisible else { return }
    let size = hosting.fittingSize
    guard abs(size.height - frame.height) > 0.5 else { return }
    setFrame(
      NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
      display: true)
    layoutContent()
    invalidateShadow()
    onRefit?(size)
  }

  func dismiss() {
    removeMonitors()
    guard isVisible else { return }
    orderOut(nil)
    onDismiss?()
  }

  private func installMonitors() {
    removeMonitors()
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: clicks,
      handler: { [weak self] _ in
        self?.dismiss()
      })
    {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: clicks.union(.keyDown),
      handler: { [weak self] event in
        guard let self else { return event }
        if event.type == .keyDown {
          let modified = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
          switch event.keyCode {
          case 53:  // Escape
            self.dismiss()
            return nil
          case 123 where !modified, 124 where !modified:  // left, right arrow
            guard let onStep = self.onStep else { return event }
            onStep(event.keyCode == 123 ? -1 : 1)
            return nil
          default: return event
          }
        }
        if event.window !== self && !self.ignoresClicks(event.window) { self.dismiss() }
        return event
      })
    {
      monitors.append(local)
    }
  }

  private func removeMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
  }
}
