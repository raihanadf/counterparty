import Foundation

// connects to markets the way aggr's worker does: one websocket per exchange endpoint,
// reconnect with backoff when a socket drops. product lists are read once at launch.

public enum MarketStatus: Sendable, Equatable {
    case connecting
    case open
    case down(String)
}

public typealias TradeHandler = @MainActor @Sendable ([Trade]) -> Void
public typealias StatusHandler = @MainActor @Sendable ([String], MarketStatus) -> Void

public struct Coin: Sendable, Identifiable, Hashable {
    public let symbol: String
    public let markets: [String]
    public var id: String { symbol }
}

// every exchange's product list, which is what turns a coin into markets
public struct Catalogs: Sendable {
    let byExchange: [String: Catalog]
    // exchanges whose product list couldn't be read, with the reason
    public let failures: [(exchange: String, reason: String)]

    // every coin with at least one market, the most widely traded first
    public var coins: [Coin] {
        var symbols: Set<String> = []
        for exchange in exchanges {
            guard let catalog = byExchange[exchange.id] else { continue }
            for pair in catalog.pairs {
                if let coin = exchange.coin(of: pair) { symbols.insert(coin) }
            }
        }
        return symbols
            .map { Coin(symbol: $0, markets: markets(for: $0)) }
            .filter { !$0.markets.isEmpty }
            .sorted { ($0.markets.count, $1.symbol) > ($1.markets.count, $0.symbol) }
    }

    // every usd/usdt/usdc perp of the coin on every exchange that lists it. for btc that's aggr's default perps
    public func markets(for coin: String) -> [String] {
        exchanges.flatMap { exchange in
            exchange.pairs(for: coin)
                .filter { byExchange[exchange.id]?.pairs.contains($0) == true }
                .map { "\(exchange.id):\($0)" }
        }
    }
}

public func loadCatalogs() async -> Catalogs {
    await withTaskGroup(of: (String, Result<Catalog, Error>).self) { group in
        for exchange in exchanges {
            group.addTask {
                do {
                    return (exchange.id, .success(try await exchange.loadCatalog()))
                } catch {
                    return (exchange.id, .failure(error))
                }
            }
        }
        var byExchange: [String: Catalog] = [:]
        var failures: [(String, String)] = []
        for await (id, result) in group {
            switch result {
            case .success(let catalog): byExchange[id] = catalog
            case .failure(let error): failures.append((id, error.localizedDescription))
            }
        }
        return Catalogs(byExchange: byExchange, failures: failures.sorted { $0.0 < $1.0 })
    }
}

// runs until the returned task is cancelled, which closes every socket
public func startFeed(markets: [String], catalogs: Catalogs, onTrades: @escaping TradeHandler, onStatus: @escaping StatusHandler) -> Task<Void, Never> {
    // one socket per exchange endpoint, a few pairs (bybit linear, binance coin margined) live on their own endpoint
    var sockets: [(exchange: any Exchange, catalog: Catalog, url: String, pairs: [String])] = []
    for exchange in exchanges {
        guard let catalog = catalogs.byExchange[exchange.id] else { continue }
        var pairsByURL: [String: [String]] = [:]
        for market in markets where market.hasPrefix(exchange.id + ":") {
            let pair = String(market.dropFirst(exchange.id.count + 1))
            pairsByURL[catalog.sockets[pair] ?? exchange.socketURL, default: []].append(pair)
        }
        for (url, pairs) in pairsByURL {
            sockets.append((exchange, catalog, url, pairs))
        }
    }

    return Task {
        await withTaskGroup(of: Void.self) { group in
            for socket in sockets {
                group.addTask {
                    await runSocket(socket.exchange, catalog: socket.catalog, url: URL(string: socket.url)!, pairs: socket.pairs, onTrades: onTrades, onStatus: onStatus)
                }
            }
        }
    }
}

private func runSocket(_ exchange: any Exchange, catalog: Catalog, url: URL, pairs: [String], onTrades: @escaping TradeHandler, onStatus: @escaping StatusHandler) async {
    let markets = pairs.map { "\(exchange.id):\($0)" }
    var attempt = 0

    while !Task.isCancelled {
        await onStatus(markets, .connecting)
        var state = SocketState(pairs: pairs)

        do {
            let socket = try await WebSocket.connect(url)
            // closing the socket is what wakes up a pending receive when the coin changes
            try await withTaskCancellationHandler {
                // exchanges like coinbase rate limit subscriptions, so space them out like aggr does
                for (index, pair) in pairs.enumerated() {
                    for message in exchange.subscriptions(pair: pair, index: index) {
                        try await socket.send(message)
                        try await Task.sleep(for: .milliseconds(150))
                    }
                }
                await onStatus(markets, .open)

                let pinger = exchange.ping.map { ping in
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
                    let trades = exchange.parse(data, catalog: catalog, state: &state)
                    if !trades.isEmpty { await onTrades(trades) }
                }
            } onCancel: {
                socket.close()
            }
            socket.close()
        } catch {
            if Task.isCancelled { return }
            let delay = min(30, 1 << min(attempt, 5))
            attempt += 1
            await onStatus(markets, .down("\(error.localizedDescription), retry in \(delay)s"))
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}
