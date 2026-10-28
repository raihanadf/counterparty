import Foundation

// connects to every market the way aggr's worker does: product lists through aggr's cors proxy,
// one websocket per exchange endpoint, reconnect with backoff when a socket drops

public enum MarketStatus: Sendable, Equatable {
    case loading
    case connecting
    case open
    case down(String)
    case unavailable(String)
}

public typealias TradeHandler = @MainActor @Sendable ([Trade]) -> Void
public typealias StatusHandler = @MainActor @Sendable ([String], MarketStatus) -> Void

private let proxy = "https://cors.aggr.trade/"

@discardableResult
public func startFeed(markets: [String], onTrades: @escaping TradeHandler, onStatus: @escaping StatusHandler) -> Task<Void, Never> {
    var pairsByExchange: [String: [String]] = [:]
    for market in markets {
        let parts = market.split(separator: ":", maxSplits: 1)
        pairsByExchange[String(parts[0]), default: []].append(String(parts[1]))
    }

    return Task {
        await withTaskGroup(of: Void.self) { group in
            for (id, pairs) in pairsByExchange {
                guard let exchange = exchanges[id] else { preconditionFailure("no adapter for exchange \(id)") }
                group.addTask { await runExchange(exchange, pairs: pairs, onTrades: onTrades, onStatus: onStatus) }
            }
        }
    }
}

private func runExchange(_ exchange: any Exchange, pairs: [String], onTrades: @escaping TradeHandler, onStatus: @escaping StatusHandler) async {
    let marketsOf = { (pairs: [String]) in pairs.map { "\(exchange.id):\($0)" } }
    await onStatus(marketsOf(pairs), .loading)

    let catalog: Catalog
    do {
        var responses: [Data] = []
        for url in exchange.productURLs {
            let (data, response) = try await URLSession.shared.data(from: URL(string: proxy + url)!)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw ProductError(errorDescription: "\(url) answered \(http.statusCode)")
            }
            responses.append(data)
        }
        catalog = try exchange.catalog(from: responses)
    } catch {
        await onStatus(marketsOf(pairs), .unavailable(error.localizedDescription))
        return
    }

    let missing = pairs.filter { !catalog.pairs.contains($0) }
    if !missing.isEmpty { await onStatus(marketsOf(missing), .unavailable("not listed by the exchange")) }

    var pairsBySocket: [String: [String]] = [:]
    for pair in pairs where catalog.pairs.contains(pair) {
        pairsBySocket[catalog.sockets[pair] ?? exchange.socketURL, default: []].append(pair)
    }

    await withTaskGroup(of: Void.self) { group in
        for (url, socketPairs) in pairsBySocket {
            let socketMarkets = marketsOf(socketPairs)
            group.addTask {
                await runSocket(exchange, catalog: catalog, url: URL(string: url)!, pairs: socketPairs, markets: socketMarkets, onTrades: onTrades, onStatus: onStatus)
            }
        }
    }
}

private func runSocket(_ exchange: any Exchange, catalog: Catalog, url: URL, pairs: [String], markets: [String], onTrades: @escaping TradeHandler, onStatus: @escaping StatusHandler) async {
    var attempt = 0

    while !Task.isCancelled {
        await onStatus(markets, .connecting)
        var state = SocketState(pairs: pairs)
        var socket: WebSocket?
        var pinger: Task<Void, Never>?

        do {
            let connected = try await WebSocket.connect(url)
            socket = connected
            // exchanges like coinbase rate limit subscriptions, so space them out like aggr does
            for (index, pair) in pairs.enumerated() {
                for message in exchange.subscriptions(pair: pair, index: index) {
                    try await connected.send(message)
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            await onStatus(markets, .open)

            if let ping = exchange.ping {
                pinger = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: ping.every)
                        try? await connected.send(ping.message)
                    }
                }
            }

            while !Task.isCancelled {
                let data = try await connected.receive()
                attempt = 0
                let trades = exchange.parse(data, catalog: catalog, state: &state)
                if !trades.isEmpty { await onTrades(trades) }
            }
        } catch {
            pinger?.cancel()
            socket?.close()
            let delay = min(30, 1 << min(attempt, 5))
            attempt += 1
            await onStatus(markets, .down("\(error.localizedDescription), retry in \(delay)s"))
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}
