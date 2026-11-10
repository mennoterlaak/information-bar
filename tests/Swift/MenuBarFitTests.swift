import CoreGraphics
import Foundation
import XCTest

@testable import InformationBar

final class MenuBarFitTests: XCTestCase {
  private func values(_ step: [MenuItemForm]) -> [Int] { step.map(\.values) }

  // MARK: - Order

  func testProvidersFollowTheSavedOrderAndNewOnesComeLast() {
    var preferences = AppPreferences()
    XCTAssertEqual(preferences.orderedCategories, ProviderCategory.allCases)
    // A removed provider and a repeated one are skipped; the rest keep their declared order.
    preferences.order = ["power", "retired", "claude", "power"]
    XCTAssertEqual(
      preferences.orderedCategories, [.power, .claude, .codex, .cursor, .vast, .pearl, .kraken])
  }

  func testMovingAProviderTakesTheTargetsPlace() {
    var preferences = AppPreferences()
    preferences.move(.power, to: .codex)
    XCTAssertEqual(
      preferences.orderedCategories, [.power, .codex, .claude, .cursor, .vast, .pearl, .kraken])
    preferences.move(.power, to: .cursor)
    XCTAssertEqual(
      preferences.orderedCategories, [.codex, .claude, .cursor, .power, .vast, .pearl, .kraken])
    let before = preferences.order
    preferences.move(.vast, to: .vast)
    XCTAssertEqual(preferences.order, before)
  }

  func testHiddenProvidersLeaveTheMenuBarButKeepTheirPlace() {
    var preferences = AppPreferences()
    preferences.order = ["kraken", "claude"]
    var claude = preferences.provider(.claude)
    claude.enabled = false
    preferences.providers["claude"] = claude
    XCTAssertEqual(preferences.menuCategories.prefix(2), [.kraken, .codex])
    XCTAssertEqual(preferences.orderedCategories.prefix(2), [.kraken, .claude])
  }

  func testOlderPreferencesGetOneGroupThatShortensWhenNeeded() throws {
    let saved = Data(#"{"providers":{},"theme":"dark","refreshInterval":120}"#.utf8)
    let preferences = try JSONDecoder().decode(AppPreferences.self, from: saved)
    XCTAssertEqual(preferences.menuLayout, .grouped)
    XCTAssertEqual(preferences.shortening, .automatic)
    XCTAssertEqual(preferences.order, [])
    var changed = preferences
    changed.menuLayout = .separate
    changed.shortening = .never
    changed.order = ["power"]
    let reloaded = try JSONDecoder().decode(
      AppPreferences.self, from: JSONEncoder().encode(changed))
    XCTAssertEqual(reloaded, changed)
  }

  // MARK: - Forms

  func testShortenedItemKeepsItsIconAndFirstValues() {
    var options = ProviderPreferences()
    options.elements = [
      MenuElement(.icon), MenuElement(.used, showLabel: true), MenuElement(.ring),
      MenuElement(.reset, showLabel: true),
    ]
    XCTAssertEqual(options.valueCount, 3)
    XCTAssertEqual(options.elements(in: .full), options.elements)
    XCTAssertFalse(options.isShortened(by: MenuItemForm(values: 3)))

    let two = options.elements(in: MenuItemForm(values: 2))
    XCTAssertEqual(two.map(\.kind), [.icon, .used, .ring])
    XCTAssertTrue(two[1].showLabel)
    // The trimmed elements are the composed ones, so the view keeps their identity.
    XCTAssertEqual(two.map(\.id), options.elements.prefix(3).map(\.id))

    let plain = options.elements(in: MenuItemForm(values: 1, labels: false))
    XCTAssertEqual(plain.map(\.kind), [.icon, .used])
    XCTAssertFalse(plain[1].showLabel)
    XCTAssertTrue(options.isShortened(by: MenuItemForm(values: 1, labels: false)))

    let iconOnly = options.elements(in: MenuItemForm(values: 0, labels: false))
    XCTAssertEqual(iconOnly.map(\.kind), [.icon])
  }

  func testItemWithoutAnIconFallsBackToOneRatherThanNothing() {
    var options = ProviderPreferences()
    options.elements = [MenuElement(.used), MenuElement(.reset)]
    XCTAssertEqual(options.elements(in: MenuItemForm(values: 1)).map(\.kind), [.used])
    XCTAssertEqual(options.elements(in: MenuItemForm(values: 0)).map(\.kind), [.icon])
    // Dropping labels from an item that has none changes nothing.
    XCTAssertFalse(options.isShortened(by: MenuItemForm(values: 2, labels: false)))
  }

  // MARK: - Ladder

  func testLadderTrimsTheLongestItemFirstThenLabelsThenFallsBackToIcons() {
    let ladder = MenuBarFit.ladder(valueCounts: [1, 3, 2])
    XCTAssertEqual(ladder.first, [.full, .full, .full])
    XCTAssertEqual(
      ladder.dropFirst().map(values),
      [
        [1, 2, 2], [1, 2, 1], [1, 1, 1],  // extra values, from the longest item
        [1, 1, 1],  // labels
        [1, 1, 0], [1, 0, 0], [0, 0, 0],  // icons, from the last item
        [0, 0, 0], [0, 0, 0],  // items leaving the menu bar, from the last
      ])
    // Nothing leaves the menu bar while there is detail left to give up, and the first item
    // always stays: a status item that does not fit is hidden by macOS as a whole.
    XCTAssertEqual(
      ladder.map { $0.map(\.hidden) }.suffix(3),
      [[false, false, false], [false, false, true], [false, true, true]])
    XCTAssertFalse(ladder.dropLast(2).contains { $0.contains(where: \.hidden) })
    // Labels stay through the first four arrangements and are gone from the fifth.
    XCTAssertEqual(ladder.map { $0.allSatisfy(\.labels) }.firstIndex(of: false), 4)
    XCTAssertFalse(ladder.dropFirst(4).contains { $0.contains(where: \.labels) })
    XCTAssertEqual(MenuBarFit.compactStep(valueCounts: [1, 3, 2]), 4)
    XCTAssertEqual(values(ladder[4]), [1, 1, 1])
  }

  func testIconOnlyItemsHaveNothingToGiveUp() {
    let ladder = MenuBarFit.ladder(valueCounts: [0, 1])
    XCTAssertEqual(ladder.dropFirst().map(values), [[0, 1], [0, 0], [0, 0]])
    XCTAssertEqual(ladder.last?.map(\.hidden), [false, true])
    // A single item has nowhere to go, and neither has an empty menu bar.
    XCTAssertFalse(MenuBarFit.ladder(valueCounts: [2]).contains { $0.contains(where: \.hidden) })
    XCTAssertEqual(MenuBarFit.ladder(valueCounts: []).count, 2)
  }

  func testLadderFollowsTheShownProvidersInTheirOrder() {
    var preferences = AppPreferences()
    preferences.order = ["pearl", "claude"]
    for category in ProviderCategory.allCases where category != .pearl && category != .claude {
      var hidden = preferences.provider(category)
      hidden.enabled = false
      preferences.providers[category.rawValue] = hidden
    }
    // Pearl shows a price and a hashrate by default, Claude one percentage.
    XCTAssertEqual(preferences.menuCategories, [.pearl, .claude])
    XCTAssertEqual(
      preferences.menuLadder.dropFirst().map(values), [[1, 1], [1, 1], [1, 0], [0, 0], [0, 0]])
    XCTAssertFalse(preferences.isShortened(.pearl, at: 0))
    XCTAssertTrue(preferences.isShortened(.pearl, at: 1))
    // Claude still shows all it has until it falls back to its icon.
    XCTAssertFalse(preferences.isShortened(.claude, at: 2))
    XCTAssertTrue(preferences.isShortened(.claude, at: 3))
    // At the last step Claude is out of the menu bar; Pearl, the first item, stays.
    XCTAssertEqual(preferences.menuForms(at: 5)[.claude]?.hidden, true)
    XCTAssertEqual(preferences.menuForms(at: 5)[.pearl]?.hidden, false)
    XCTAssertFalse(preferences.isShortened(.kraken, at: 4))
  }

  // MARK: - Choosing a step

  private let widths: [CGFloat] = [400, 340, 300, 220, 120]
  private func step(current: Int?, limit: CGFloat?) -> Int {
    MenuBarFit.step(count: widths.count, current: current, limit: limit, slack: 20) { widths[$0] }
  }

  func testItemsShrinkAsSoonAsTheyStopFitting() {
    XCTAssertEqual(step(current: nil, limit: nil), 0)
    XCTAssertEqual(step(current: nil, limit: 400), 0)
    XCTAssertEqual(step(current: 0, limit: 399), 1)
    XCTAssertEqual(step(current: 1, limit: 250), 3)
    // Nothing fits: icons only is the best there is.
    XCTAssertEqual(step(current: nil, limit: 50), 4)
  }

  func testItemsGrowBackOnlyWithRoomToSpare() {
    // Step 1 fits 345, but not with the slack, so the narrower arrangement stays.
    XCTAssertEqual(step(current: 2, limit: 345), 2)
    XCTAssertEqual(step(current: 2, limit: 360), 1)
    // Growing never overshoots what fits outright.
    XCTAssertEqual(step(current: 4, limit: 410), 1)
    XCTAssertEqual(step(current: 4, limit: 420), 0)
    // A step from before the composition changed is clamped to the new ladder.
    XCTAssertEqual(step(current: 9, limit: 125), 4)
  }

  func testWithoutALimitNothingIsShortened() {
    XCTAssertEqual(step(current: 3, limit: nil), 0)
    XCTAssertEqual(MenuBarFit.step(count: 0, current: nil, limit: 10, slack: 0) { _ in 0 }, 0)
  }

  // MARK: - Room in the menu bar

  func testRoomIsTheStripBesideTheNotchOrHalfTheDisplay() {
    // A 14-inch MacBook Pro at its default scale has about 664 points right of the camera.
    XCTAssertEqual(MenuBarSpace.budget(screenWidth: 1512, rightOfNotch: 664), 664)
    XCTAssertEqual(MenuBarSpace.budget(screenWidth: 3008, rightOfNotch: nil), 1504)
    XCTAssertEqual(MenuBarSpace.budget(screenWidth: 1440, rightOfNotch: 0), 720)
    XCTAssertEqual(MenuBarSpace.limit(budget: 664, others: 334, margin: 4), 326)
    XCTAssertEqual(MenuBarSpace.limit(budget: 300, others: 334, margin: 4), 0)
  }

  func testOtherAppsItemsAreWhatIsLeftBesideOurs() {
    let screen = CGRect(x: 3008, y: 0, width: 3008, height: 1692)
    let group = CGRect(x: 5000, y: 1660, width: 500, height: 33)
    XCTAssertEqual(MenuBarSpace.others(items: [group], screen: screen), 516)
    // Separate items with another app's 40pt item between them.
    let left = CGRect(x: 5000, y: 1660, width: 100, height: 33)
    let right = CGRect(x: 5140, y: 1660, width: 60, height: 33)
    XCTAssertEqual(MenuBarSpace.others(items: [right, left], screen: screen), 856)
  }

  func testFramesThatAreNotOnTheDisplayAreNotMeasured() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    XCTAssertNil(MenuBarSpace.others(items: [], screen: screen))
    // Not laid out yet.
    XCTAssertNil(
      MenuBarSpace.others(items: [CGRect(x: 0, y: 0, width: 47, height: 0)], screen: screen))
    // macOS leaves a hidden item's frame where it was, running past the display's edge.
    XCTAssertNil(
      MenuBarSpace.others(items: [CGRect(x: 900, y: 950, width: 700, height: 33)], screen: screen))
    // On another display.
    XCTAssertNil(
      MenuBarSpace.others(items: [CGRect(x: 2000, y: 950, width: 80, height: 33)], screen: screen))
    // Behind the camera housing, which leaves 664 points to its right on this display.
    let behind = CGRect(x: 800, y: 950, width: 300, height: 33)
    XCTAssertEqual(MenuBarSpace.others(items: [behind], screen: screen), 412)
    XCTAssertNil(MenuBarSpace.others(items: [behind], screen: screen, rightOfNotch: 664))
    let beside = CGRect(x: 900, y: 950, width: 300, height: 33)
    XCTAssertEqual(MenuBarSpace.others(items: [beside], screen: screen, rightOfNotch: 664), 312)
  }

  func testAPointOpensTheProviderDrawnThere() {
    let ends: [CGFloat] = [53, 113, 180]
    XCTAssertEqual(MenuBarFit.cell(at: 0, ends: ends), 0)
    XCTAssertEqual(MenuBarFit.cell(at: 53, ends: ends), 1)
    XCTAssertEqual(MenuBarFit.cell(at: 179.5, ends: ends), 2)
    // The padding around the status item belongs to the nearest provider.
    XCTAssertEqual(MenuBarFit.cell(at: -8, ends: ends), 0)
    XCTAssertEqual(MenuBarFit.cell(at: 188, ends: ends), 2)
    XCTAssertNil(MenuBarFit.cell(at: 10, ends: []))
  }

  func testArrowKeysWrapAroundTheShownProviders() {
    let shown: [ProviderCategory] = [.codex, .claude, .power]
    XCTAssertEqual(MenuBarFit.neighbour(of: .claude, in: shown, offset: 1), .power)
    XCTAssertEqual(MenuBarFit.neighbour(of: .power, in: shown, offset: 1), .codex)
    XCTAssertEqual(MenuBarFit.neighbour(of: .codex, in: shown, offset: -1), .power)
    XCTAssertNil(MenuBarFit.neighbour(of: ProviderCategory.codex, in: [.codex], offset: 1))
    XCTAssertNil(MenuBarFit.neighbour(of: .kraken, in: shown, offset: 1))
  }
}
