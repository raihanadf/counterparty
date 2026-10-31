import Foundation

// the live order book of one market: the orders resting above and below the price right now.
// the dom ladder in Dom.swift is something else, it counts trades that already happened.

public struct BookLevel: Sendable, Equatable {
    public let price: Double
    public let size: Double
}

public struct Book: Sendable, Equatable {
    public let market: String
    // best (highest) bid first
    public let bids: [BookLevel]
    // best (lowest) ask first
    public let asks: [BookLevel]
    // unix milliseconds
    public let time: Double

    public var mid: Double? {
        guard let bid = bids.first?.price, let ask = asks.first?.price else { return nil }
        return (bid + ask) / 2
    }

    public var spread: Double? {
        guard let bid = bids.first?.price, let ask = asks.first?.price else { return nil }
        return ask - bid
    }
}

public typealias BookHandler = @MainActor @Sendable (Book) -> Void
// nil means the book is up to date, otherwise why it stopped
public typealias BookStatusHandler = @MainActor @Sendable (String?) -> Void

// books are only shown where the size is the coin itself: usdt and usdc margined perps.
// inverse books are counted in usd contracts, a different unit, so they'd be a different ladder
public func hasBook(_ market: String) -> Bool {
    let parts = market.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return false }
    let pair = parts[1].uppercased()
    return switch parts[0] {
    case "BINANCE_FUTURES": pair.hasSuffix("USDT") || pair.hasSuffix("USDC")
    case "BYBIT": pair.hasSuffix("USDT") || pair.hasSuffix("PERP")
    case "OKEX": pair.hasSuffix("-USDT-SWAP")
    case "DERIBIT": pair.hasSuffix("_USDC-PERPETUAL")
    default: false
    }
}

private enum Venue {
    case binance, bybit, okx, deribit
}

private struct Spec {
    let venue: Venue
    let url: String
    let messages: [String]
    let ping: (message: String, every: Duration)?
}

private func spec(for market: String) -> Spec? {
    let parts = market.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    let pair = String(parts[1])
    switch parts[0] {
    case "BINANCE_FUTURES":
        // top 20 levels, a fresh snapshot every 100ms, no book to maintain
        return Spec(
            venue: .binance,
            url: "wss://fstream.binance.com/public/ws",
            messages: [#"{"method":"SUBSCRIBE","params":["\#(pair.lowercased())@depth20@100ms"],"id":1}"#],
            ping: nil
        )
    case "BYBIT":
        return Spec(
            venue: .bybit,
            url: "wss://stream.bybit.com/v5/public/linear",
            messages: [#"{"op":"subscribe","args":["orderbook.50.\#(pair)"]}"#],
            ping: (#"{"op":"ping"}"#, .seconds(20))
        )
    case "OKEX":
        // 400 levels, snapshot then updates
        return Spec(
            venue: .okx,
            url: "wss://ws.okx.com:8443/ws/v5/public",
            messages: [#"{"op":"subscribe","args":[{"channel":"books","instId":"\#(pair)"}]}"#],
            ping: ("ping", .seconds(25))
        )
    case "DERIBIT":
        // top 20, a fresh snapshot every 100ms
        return Spec(
            venue: .deribit,
            url: "wss://www.deribit.com/ws/api/v2",
            messages: [#"{"method":"public/subscribe","params":{"channels":["book.\#(pair).none.20.100ms"]}}"#],
            ping: (#"{"method":"public/ping"}"#, .seconds(45))
        )
    default:
        return nil
    }
}

// price -> size for each side, kept between messages because bybit and okx send changes
private struct Sides {
    var bids: [Double: Double] = [:]
    var asks: [Double: Double] = [:]
    var published: Double = 0

    mutating func replace(bids: [[Double]], asks: [[Double]]) {
        self.bids = Dictionary(bids.map { ($0[0], $0[1]) }, uniquingKeysWith: { $1 })
        self.asks = Dictionary(asks.map { ($0[0], $0[1]) }, uniquingKeysWith: { $1 })
    }

    // static so the caller can merge into the sides it's already holding
    static func merge(_ levels: [[Double]], into side: inout [Double: Double]) {
        for level in levels {
            if level[1] == 0 { side[level[0]] = nil } else { side[level[0]] = level[1] }
        }
    }

    // the best levels, sizes in the coin like the trades (okx books count contracts of 0.01 btc)
    func book(_ market: String, pair: String, catalog: Catalog, time: Double, depth: Int) -> Book {
        let bestBids = bids.sorted { $0.key > $1.key }.prefix(depth)
        let bestAsks = asks.sorted { $0.key < $1.key }.prefix(depth)
        let level = { (entry: (key: Double, value: Double)) in
            BookLevel(price: entry.key, size: catalog.toBase(pair, size: entry.value, price: entry.key))
        }
        return Book(market: market, bids: bestBids.map(level), asks: bestAsks.map(level), time: time)
    }
}

private struct BinanceDepth: Decodable {
    let b: [[String]]
    let a: [[String]]
}

private struct BybitDepth: Decodable {
    struct Data: Decodable {
        let b: [[String]]
        let a: [[String]]
    }
    let type: String
    let data: Data
}

private struct OkxDepth: Decodable {
    struct Row: Decodable {
        let bids: [[String]]
        let asks: [[String]]
    }
    let action: String
    let data: [Row]
}

private struct DeribitDepth: Decodable {
    struct Params: Decodable {
        struct Data: Decodable {
            let bids: [[Double]]
            let asks: [[Double]]
        }
        let data: Data
    }
    let params: Params
}

private func levels(_ rows: [[String]]) -> [[Double]] {
    rows.compactMap { row in
        guard row.count >= 2, let price = Double(row[0]), let size = Double(row[1]) else { return nil }
        return [price, size]
    }
}

// reads one message into the sides, true when the book changed
private func apply(_ data: Data, _ venue: Venue, _ sides: inout Sides) -> Bool {
    switch venue {
    case .binance:
        guard let message = try? JSONDecoder().decode(BinanceDepth.self, from: data) else { return false }
        sides.replace(bids: levels(message.b), asks: levels(message.a))
        return true
    case .bybit:
        guard let message = try? JSONDecoder().decode(BybitDepth.self, from: data) else { return false }
        let bids = levels(message.data.b), asks = levels(message.data.a)
        if message.type == "snapshot" {
            sides.replace(bids: bids, asks: asks)
        } else {
            Sides.merge(bids, into: &sides.bids)
            Sides.merge(asks, into: &sides.asks)
        }
        return true
    case .okx:
        guard let message = try? JSONDecoder().decode(OkxDepth.self, from: data), let row = message.data.first else { return false }
        let bids = levels(row.bids), asks = levels(row.asks)
        if message.action == "snapshot" {
            sides.replace(bids: bids, asks: asks)
        } else {
            Sides.merge(bids, into: &sides.bids)
            Sides.merge(asks, into: &sides.asks)
        }
        return true
    case .deribit:
        guard let message = try? JSONDecoder().decode(DeribitDepth.self, from: data) else { return false }
        sides.replace(bids: message.params.data.bids, asks: message.params.data.asks)
        return true
    }
}

// keeps the book of one market flowing until the task is cancelled
public func startBook(market: String, catalogs: Catalogs, onBook: @escaping BookHandler, onStatus: @escaping BookStatusHandler) -> Task<Void, Never> {
    guard let spec = spec(for: market) else { preconditionFailure("no book stream for \(market), check hasBook first") }
    let parts = market.split(separator: ":", maxSplits: 1)
    let pair = String(parts[1])
    guard let catalog = catalogs.byExchange[String(parts[0])] else { preconditionFailure("no product list for \(market)") }
    return Task {
        var attempt = 0
        while !Task.isCancelled {
            await onStatus(nil)
            var sides = Sides()

            do {
                let socket = try await WebSocket.connect(URL(string: spec.url)!)
                try await withTaskCancellationHandler {
                    for message in spec.messages { try await socket.send(message) }

                    let pinger = spec.ping.map { ping in
                        Task {
                            while !Task.isCancelled {
                                try? await Task.sleep(for: ping.every)
                                try? await socket.send(ping.message)
                            }
                        }
                    }
                    defer { pinger?.cancel() }

                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        attempt = 0
                        guard apply(data, spec.venue, &sides) else { continue }
                        // the ladder is read by eye, ten updates a second is plenty
                        let now = Date().timeIntervalSince1970
                        guard now - sides.published >= 0.1 else { continue }
                        sides.published = now
                        await onBook(sides.book(market, pair: pair, catalog: catalog, time: now * 1000, depth: 30))
                    }
                } onCancel: {
                    socket.close()
                }
                socket.close()
            } catch {
                if Task.isCancelled { return }
                await onStatus(error.localizedDescription)
                let delay = min(30, 1 << min(attempt, 5))
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }
}
