import AppKit
import Foundation

/// What Kraken's live price feed is doing, for Settings and the dropdown.
enum KrakenFeedState: Equatable {
  /// Live prices are off, or there are no current balances to price.
  case off
  case connecting
  /// Prices are streaming for this many markets.
  case live(markets: Int)
  /// The connection failed; the next attempt starts at this time.
  case retrying(at: Date)
  /// The Mac or its displays are asleep.
  case paused

  var isLive: Bool {
    if case .live = self { return true }
    return false
  }
}

/// The WebSocket calls the feed makes, so tests can stand in for Kraken.
protocol PriceSocket: AnyObject {
  func send(_ text: String)
  /// The next text message; throws once the connection has ended.
  func receive() async throws -> String
  func close()
}

final class URLSessionPriceSocket: PriceSocket {
  private let task: URLSessionWebSocketTask

  init(url: URL, session: URLSession) {
    task = session.webSocketTask(with: url)
    task.resume()
  }

  func send(_ text: String) {
    // Errors are not lost: a broken connection fails `receive`, a silent one trips the watchdog.
    task.send(.string(text)) { _ in }
  }

  func receive() async throws -> String {
    switch try await task.receive() {
    case .string(let text): return text
    case .data(let data): return String(decoding: data, as: UTF8.self)
    @unknown default: return ""
    }
  }

  func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// Last trades in a ticker snapshot or update from Kraken's WebSocket v2 feed; nil for any
/// other message, such as heartbeats, status and subscription replies.
func krakenTickerPrices(_ text: String) -> [String: Double]? {
  guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
    object["channel"] as? String == "ticker", let rows = object["data"] as? [[String: Any]]
  else { return nil }
  var prices: [String: Double] = [:]
  for row in rows {
    guard let symbol = row["symbol"] as? String, let last = row["last"] as? Double,
      last.isFinite, last > 0
    else { continue }
    prices[symbol] = last
  }
  return prices
}

/// Streams the last trade of each market behind the portfolio's prices from Kraken's public
/// WebSocket feed, which needs no key. New prices are reported at most once per `interval`.
@MainActor
final class KrakenPriceFeed {
  static let url = URL(string: "wss://ws.kraken.com/v2")!

  private(set) var state = KrakenFeedState.off {
    didSet { if state != oldValue { onState?() } }
  }
  /// Last trade per subscribed market.
  private(set) var prices: [String: Double] = [:]
  /// The prices are known to be current up to this moment.
  private(set) var heardAt: Date?
  var onPrices: (() -> Void)?
  var onState: (() -> Void)?

  private let connect: () -> PriceSocket
  private let interval: Duration
  private var socket: PriceSocket?
  /// Identifies the current connection; callbacks from older ones are ignored.
  private var connection = 0
  private var opened = false
  private var openedAt = ContinuousClock.now
  private var lastMessage = ContinuousClock.now
  private var wanted: Set<String> = []
  private var subscribed: Set<String> = []
  private var enabled = false
  private var asleep = false
  private var screensAsleep = false
  private var failures = 0
  private var retry: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var publishPending = false
  private var lastPublish: ContinuousClock.Instant?
  private var observers: [NSObjectProtocol] = []

  init(interval: Duration = .seconds(1), connect: (() -> PriceSocket)? = nil) {
    self.interval = interval
    if let connect {
      self.connect = connect
    } else {
      let session = URLSession(configuration: .ephemeral)
      self.connect = { URLSessionPriceSocket(url: KrakenPriceFeed.url, session: session) }
    }
    observe(NSWorkspace.willSleepNotification) { $0.asleep = true }
    observe(NSWorkspace.didWakeNotification) { $0.asleep = false }
    observe(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
    observe(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
  }

  /// Streams `symbols` while `enabled`; otherwise disconnects and forgets the prices.
  func stream(_ symbols: Set<String>, enabled: Bool) {
    wanted = symbols
    self.enabled = enabled && !symbols.isEmpty
    reconcile()
  }

  /// Prices to apply to balances fetched at `date`: all of them while streaming, and after the
  /// connection ends only while they are still newer than that fetch.
  func prices(after date: Date) -> [String: Double] {
    if state.isLive { return prices }
    guard let heardAt, heardAt > date else { return [:] }
    return prices
  }

  private func reconcile() {
    guard enabled else {
      close()
      prices = [:]
      heardAt = nil
      state = .off
      return
    }
    guard !asleep && !screensAsleep else {
      close()
      state = .paused
      return
    }
    if socket == nil {
      if retry == nil { open() }
    } else if opened {
      resubscribe()
    }
  }

  private func open() {
    connection += 1
    let id = connection
    let socket = connect()
    self.socket = socket
    opened = false
    subscribed = []
    openedAt = .now
    lastMessage = .now
    state = .connecting
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
        guard let self, self.connection == id else { return }
        // Kraken sends a heartbeat every second while subscribed.
        if ContinuousClock.now - self.lastMessage > .seconds(15) {
          self.failed(id)
          return
        }
      }
    }
    Task { [weak self] in
      while true {
        let text: String
        do { text = try await socket.receive() } catch {
          self?.failed(id)
          return
        }
        guard let self, self.connection == id else { return }
        self.receive(text)
      }
    }
  }

  private func receive(_ text: String) {
    lastMessage = .now
    heardAt = Date()
    if !opened {
      // Kraken's first message confirms the connection is open.
      opened = true
      resubscribe()
    }
    guard let update = krakenTickerPrices(text) else { return }
    if ContinuousClock.now - openedAt > .seconds(30) { failures = 0 }
    var changed = false
    for (symbol, price) in update where subscribed.contains(symbol) && prices[symbol] != price {
      prices[symbol] = price
      changed = true
    }
    state = .live(markets: prices.count)
    if changed { schedulePublish() }
  }

  private func resubscribe() {
    let removed = subscribed.subtracting(wanted)
    let added = wanted.subtracting(subscribed)
    if !removed.isEmpty { send("unsubscribe", removed) }
    if !added.isEmpty { send("subscribe", added) }
    subscribed = wanted
    prices = prices.filter { wanted.contains($0.key) }
  }

  private func send(_ method: String, _ symbols: Set<String>) {
    var params: [String: Any] = ["channel": "ticker", "symbol": symbols.sorted()]
    if method == "subscribe" {
      params["event_trigger"] = "trades"
      params["snapshot"] = true
    }
    guard
      let data = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])
    else { return }
    socket?.send(String(decoding: data, as: UTF8.self))
  }

  private func failed(_ id: Int) {
    guard id == connection else { return }
    close()
    failures += 1
    let delay = min(300, pow(2, Double(min(failures, 9))))
    state = .retrying(at: Date().addingTimeInterval(delay))
    retry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled else { return }
      self.retry = nil
      self.reconcile()
    }
  }

  private func close() {
    connection += 1
    socket?.close()
    socket = nil
    opened = false
    subscribed = []
    watchdog?.cancel()
    watchdog = nil
    retry?.cancel()
    retry = nil
  }

  private func schedulePublish() {
    guard !publishPending else { return }
    publishPending = true
    let wait = lastPublish.map { max(.zero, interval - (ContinuousClock.now - $0)) } ?? .zero
    Task { [weak self] in
      try? await Task.sleep(for: wait, tolerance: .milliseconds(100))
      guard let self else { return }
      self.publishPending = false
      self.lastPublish = .now
      self.onPrices?()
    }
  }

  private func observe(
    _ name: Notification.Name, _ change: @escaping @MainActor @Sendable (KrakenPriceFeed) -> Void
  ) {
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          change(self)
          self.reconcile()
        }
      })
  }
}
