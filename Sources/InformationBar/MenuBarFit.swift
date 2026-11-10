import CoreGraphics
import Foundation

/// How much of one composed item is drawn. When the menu bar is short of room, items give up
/// detail in steps: extra values first, then labels, then everything but the icon.
struct MenuItemForm: Equatable {
  /// Elements kept besides the icon. Anything at or above the composed count keeps them all.
  var values = Int.max
  /// Pool and asset prefixes, as in "5h 68%".
  var labels = true

  static let full = MenuItemForm()
}

extension ProviderPreferences {
  /// Elements besides the icon: values, rings and graphs.
  var valueCount: Int { elements.filter { $0.kind != .icon }.count }

  /// The composed elements as drawn in `form`. An item never becomes empty: without values it
  /// keeps its icon, and a composition without an icon gets one so it stays recognizable.
  func elements(in form: MenuItemForm) -> [MenuElement] {
    var kept: [MenuElement] = []
    var values = 0
    var hasIcon = false
    for var element in elements {
      if element.kind == .icon {
        // A second icon adds nothing once the item is down to its icon.
        if form.values == 0 && hasIcon { continue }
        hasIcon = true
      } else {
        guard values < form.values else { continue }
        values += 1
        if !form.labels { element.showLabel = false }
      }
      kept.append(element)
    }
    return kept.isEmpty ? [MenuElement(.icon)] : kept
  }

  /// A copy whose menu bar composition is trimmed to `form`.
  func shortened(to form: MenuItemForm) -> ProviderPreferences {
    var copy = self
    copy.elements = elements(in: form)
    return copy
  }

  /// Whether `form` leaves out part of the composition.
  func isShortened(by form: MenuItemForm) -> Bool {
    !elements.isEmpty && elements(in: form) != elements
  }
}

extension AppPreferences {
  /// The arrangements the shown providers can take, from complete to icons only.
  var menuLadder: [[MenuItemForm]] {
    MenuBarFit.ladder(valueCounts: menuCategories.map { provider($0).valueCount })
  }

  /// The form of each shown provider at `step` of the ladder.
  func menuForms(at step: Int) -> [ProviderCategory: MenuItemForm] {
    let ladder = menuLadder
    return Dictionary(
      uniqueKeysWithValues: zip(menuCategories, ladder[min(max(0, step), ladder.count - 1)]))
  }

  /// Whether the provider is drawn with less than its composition at `step`.
  func isShortened(_ category: ProviderCategory, at step: Int) -> Bool {
    menuForms(at: step)[category].map { provider(category).isShortened(by: $0) } ?? false
  }
}

/// Chooses how much each item shows so that all of them fit the menu bar.
enum MenuBarFit {
  /// Every arrangement from complete to icons only, one form per item in menu bar order.
  /// Each step is narrower than the one before:
  /// 1. the item with the most values loses its last one, until none shows more than one;
  /// 2. labels go;
  /// 3. items fall back to their icon, starting with the last.
  /// Ties in step 1 also start with the last item, so earlier items keep their detail longest.
  static func ladder(valueCounts: [Int]) -> [[MenuItemForm]] {
    var kept = valueCounts.map { max(0, $0) }
    var steps = [kept.map { _ in MenuItemForm.full }]
    while let most = kept.max(), most > 1, let index = kept.lastIndex(of: most) {
      kept[index] -= 1
      steps.append(kept.map { MenuItemForm(values: $0) })
    }
    steps.append(kept.map { MenuItemForm(values: $0, labels: false) })
    for index in kept.indices.reversed() where kept[index] > 0 {
      kept[index] = 0
      steps.append(kept.map { MenuItemForm(values: $0, labels: false) })
    }
    return steps
  }

  /// The first step at which every item shows one unlabeled value at most: the form used when
  /// items are always shortened.
  static func compactStep(valueCounts: [Int]) -> Int {
    valueCounts.reduce(0) { $0 + max(0, $1 - 1) } + 1
  }

  /// The step to draw. Items shrink as soon as they stop fitting `limit`, but only grow back
  /// once the roomier step fits with `slack` to spare, so a width near the limit does not make
  /// the menu bar flicker between two arrangements. Without a limit nothing is shortened.
  /// - Parameters:
  ///   - count: number of steps; `width` is asked for steps below it.
  ///   - current: the step drawn now, nil when the items or their composition changed.
  static func step(
    count: Int, current: Int?, limit: CGFloat?, slack: CGFloat, width: (Int) -> CGFloat
  ) -> Int {
    guard count > 0 else { return 0 }
    guard let limit else { return 0 }
    func first(fitting room: CGFloat) -> Int {
      (0..<count).first { width($0) <= room } ?? count - 1
    }
    let needed = first(fitting: limit)
    guard let current = current.map({ min($0, count - 1) }), needed < current else {
      return needed
    }
    return min(current, first(fitting: limit - slack))
  }

  /// Which of the cells laid side by side holds `x`, given each cell's right edge. A point
  /// beyond either end counts for the nearest cell, so the padding around a status item
  /// still opens a dropdown.
  static func cell(at x: CGFloat, ends: [CGFloat]) -> Int? {
    guard !ends.isEmpty else { return nil }
    return ends.firstIndex { x < $0 } ?? ends.count - 1
  }

  /// The item `offset` places after `item`, wrapping around at either end. Nil when there is
  /// no other item to go to.
  static func neighbour<Item: Equatable>(of item: Item, in items: [Item], offset: Int) -> Item? {
    guard items.count > 1, let index = items.firstIndex(of: item) else { return nil }
    let count = items.count
    return items[((index + offset) % count + count) % count]
  }
}

/// Room for status items on a display.
enum MenuBarSpace {
  /// Points of menu bar the status items can use. On a display with a camera housing that is
  /// the strip to its right. Elsewhere the right half is kept free of the app's own items, so
  /// they stay clear of the frontmost app's menus.
  static func budget(screenWidth: CGFloat, rightOfNotch: CGFloat?) -> CGFloat {
    if let rightOfNotch, rightOfNotch > 0 { return rightOfNotch }
    return screenWidth / 2
  }

  /// Width left for this app's items once the other apps' items have taken theirs.
  static func limit(budget: CGFloat, others: CGFloat, margin: CGFloat) -> CGFloat {
    max(0, budget - max(0, others) - margin)
  }

  /// Width taken by other apps' status items between this app's leftmost item and the
  /// display's right edge. Nil when a frame is not where status items are drawn: off the
  /// display or behind its camera housing, as while macOS has an item hidden for lack of room.
  static func others(items: [CGRect], screen: CGRect, rightOfNotch: CGFloat? = nil) -> CGFloat? {
    guard let leading = items.map(\.minX).min(), !items.isEmpty else { return nil }
    var start = screen.minX
    if let rightOfNotch, rightOfNotch > 0 { start = screen.maxX - rightOfNotch }
    for frame in items {
      guard frame.width > 0, frame.height > 0, frame.minX >= start - 0.5,
        frame.maxX <= screen.maxX + 0.5
      else { return nil }
    }
    let own = items.reduce(0) { $0 + $1.width }
    let others = screen.maxX - leading - own
    return others >= -0.5 ? max(0, others) : nil
  }
}
