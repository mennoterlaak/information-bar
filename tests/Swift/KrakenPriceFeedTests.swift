import AppKit
import Foundation
import XCTest

@testable import InformationBar

/// Plays Kraken's side of one WebSocket connection.
private final class FakeSocket: PriceSocket {
  private(set) var sent: [[String: Any]] = []
  private(set) var closed = false
  private let continuation: AsyncThrowingStream<String, Error>.Continuation
  private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator

  init() {
    let (messages, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    self.continuation = continuation
    iterator = messages.makeAsyncIterator()
  }

  func send(_ text: String) {
    sent.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:])
  }

  func receive() async throws -> String {
    guard let text = try await iterator.next() else { throw URLError(.networkConnectionLost) }
    return text
  }

  func close() {
    closed = true
    continuation.finish()
  }

  func deliver(_ text: String) { continuation.yield(text) }
  func drop() { continuation.finish(throwing: URLError(.networkConnectionLost)) }
}

private final class Connections {
  var sockets: [FakeSocket] = []
}

@MainActor
final class KrakenPriceFeedTests: XCTestCase {
  private let status =
    #"{"channel":"status","type":"update","data":[{"system":"online","api_version":"v2"}]}"#

  private func feed(interval: Duration = .milliseconds(10)) -> (KrakenPriceFeed, Connections) {
    let connections = Connections()
    let feed = KrakenPriceFeed(interval: interval) {
      let socket = FakeSocket()
      connections.sockets.append(socket)
      return socket
    }
    return (feed, connections)
  }

  private func ticker(_ prices: [String: Double], type: String = "update") -> String {
    let rows = prices.map { ["symbol": $0.key, "last": $0.value, "bid": $0.value * 0.999] }
    let data = try! JSONSerialization.data(
      withJSONObject: ["channel": "ticker", "type": type, "data": rows])
    return String(decoding: data, as: UTF8.self)
  }

  /// Lets the feed's tasks handle what was delivered.
  private func settle(_ milliseconds: Int = 50) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
  }

  private func requests(_ socket: FakeSocket) -> [(method: String?, symbols: [String]?)] {
    socket.sent.map {
      ($0["method"] as? String, ($0["params"] as? [String: Any])?["symbol"] as? [String])
    }
  }

  func testSubscribesOnceOpenAndKeepsOnlyItsOwnMarkets() async throws {
    let (feed, connections) = feed()
    var published = 0
    feed.onPrices = { published += 1 }
    feed.stream(["EUR/USD", "BTC/EUR"], enabled: true)
    XCTAssertEqual(feed.state, .connecting)
    let socket = try XCTUnwrap(connections.sockets.first)
    XCTAssertTrue(socket.sent.isEmpty)

    socket.deliver(status)
    try await settle()
    XCTAssertEqual(requests(socket).map(\.method), ["subscribe"])
    XCTAssertEqual(requests(socket).map(\.symbols), [["BTC/EUR", "EUR/USD"]])
    let params = try XCTUnwrap(socket.sent.first?["params"] as? [String: Any])
    XCTAssertEqual(params["channel"] as? String, "ticker")
    XCTAssertEqual(params["event_trigger"] as? String, "trades")

    socket.deliver(ticker(["BTC/EUR": 74000, "EUR/USD": 1.16, "ETH/EUR": 2000], type: "snapshot"))
    try await settle()
    XCTAssertEqual(feed.prices, ["BTC/EUR": 74000, "EUR/USD": 1.16])
    XCTAssertEqual(feed.state, .live(markets: 2))
    XCTAssertEqual(published, 1)
  }

  func testUpdatesWithinOneIntervalArePublishedOnce() async throws {
    let (feed, connections) = feed(interval: .milliseconds(300))
    var published: [Double] = []
    feed.onPrices = { [unowned feed] in published.append(feed.prices["BTC/EUR"] ?? 0) }
    feed.stream(["BTC/EUR"], enabled: true)
    let socket = try XCTUnwrap(connections.sockets.first)
    socket.deliver(status)
    socket.deliver(ticker(["BTC/EUR": 1], type: "snapshot"))
    try await settle()
    XCTAssertEqual(published, [1])

    socket.deliver(ticker(["BTC/EUR": 2]))
    socket.deliver(ticker(["BTC/EUR": 3]))
    try await settle()
    XCTAssertEqual(published, [1])
    try await settle(500)
    XCTAssertEqual(published, [1, 3])
  }

  func testChangedHoldingsResubscribeOnlyTheDifference() async throws {
    let (feed, connections) = feed()
    feed.stream(["BTC/EUR", "EUR/USD"], enabled: true)
    let socket = try XCTUnwrap(connections.sockets.first)
    socket.deliver(status)
    socket.deliver(ticker(["BTC/EUR": 74000, "EUR/USD": 1.16], type: "snapshot"))
    try await settle()

    feed.stream(["BTC/EUR", "ETH/EUR"], enabled: true)
    XCTAssertEqual(connections.sockets.count, 1)
    let changes = requests(socket).dropFirst()
    XCTAssertEqual(changes.map(\.method), ["unsubscribe", "subscribe"])
    XCTAssertEqual(changes.map(\.symbols), [["EUR/USD"], ["ETH/EUR"]])
    XCTAssertEqual(feed.prices, ["BTC/EUR": 74000])
  }

  func testAfterADropPricesLastOnlyUntilNewerBalancesArrive() async throws {
    let (feed, connections) = feed()
    feed.stream(["BTC/EUR"], enabled: true)
    let socket = try XCTUnwrap(connections.sockets.first)
    let fetchedBefore = Date()
    socket.deliver(status)
    socket.deliver(ticker(["BTC/EUR": 74000], type: "snapshot"))
    try await settle()
    XCTAssertEqual(feed.prices(after: Date()), ["BTC/EUR": 74000])

    socket.drop()
    try await settle()
    guard case .retrying = feed.state else { return XCTFail("Unexpected \(feed.state)") }
    XCTAssertTrue(socket.closed)
    XCTAssertEqual(feed.prices(after: fetchedBefore), ["BTC/EUR": 74000])
    XCTAssertEqual(feed.prices(after: Date()), [:])
  }

  func testTurningOffDisconnectsAndForgetsPrices() async throws {
    let (feed, connections) = feed()
    feed.stream(["BTC/EUR"], enabled: true)
    let socket = try XCTUnwrap(connections.sockets.first)
    socket.deliver(status)
    socket.deliver(ticker(["BTC/EUR": 74000], type: "snapshot"))
    try await settle()

    feed.stream(["BTC/EUR"], enabled: false)
    XCTAssertEqual(feed.state, .off)
    XCTAssertTrue(socket.closed)
    XCTAssertEqual(feed.prices(after: .distantPast), [:])
    // Nothing to follow is the same as off.
    feed.stream([], enabled: true)
    XCTAssertEqual(feed.state, .off)
    XCTAssertEqual(connections.sockets.count, 1)
  }

  func testSleepingDisplaysPauseTheFeedUntilTheyWake() async throws {
    let (feed, connections) = feed()
    feed.stream(["BTC/EUR"], enabled: true)
    let center = NSWorkspace.shared.notificationCenter
    center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    try await settle()
    XCTAssertEqual(feed.state, .paused)
    XCTAssertEqual(connections.sockets.map(\.closed), [true])

    center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    try await settle()
    XCTAssertEqual(feed.state, .connecting)
    XCTAssertEqual(connections.sockets.count, 2)
  }

  func testTickerMessagesYieldLastTradesAndEverythingElseIsIgnored() {
    XCTAssertEqual(
      krakenTickerPrices(
        #"{"channel":"ticker","type":"snapshot","data":[{"symbol":"BTC/EUR","last":74101.6},{"symbol":"DOGE/EUR","last":0.0772},{"symbol":"NEW/EUR"},{"symbol":"ZERO/EUR","last":0}]}"#
      ), ["BTC/EUR": 74101.6, "DOGE/EUR": 0.0772])
    XCTAssertEqual(
      krakenTickerPrices(
        #"{"channel":"ticker","type":"update","data":[{"symbol":"BTC/EUR","last":74000}]}"#),
      ["BTC/EUR": 74000])
    XCTAssertNil(krakenTickerPrices(#"{"channel":"heartbeat"}"#))
    XCTAssertNil(
      krakenTickerPrices(
        #"{"error":"Currency pair not supported NOPE/EUR","method":"subscribe","success":false,"symbol":"NOPE/EUR"}"#
      ))
    XCTAssertNil(krakenTickerPrices("not json"))
  }
}
