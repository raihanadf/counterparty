import Foundation

// exchange adapters, ported from aggr's worker/exchanges.
// endpoints, subscriptions and size normalization match aggr so the numbers line up.

public enum Side: String, Sendable, Decodable {
    case buy, sell
}

public struct Trade: Sendable {
    public let market: String
    // unix milliseconds
    public let timestamp: Double
    public let price: Double
    // size in base currency (btc), aggr multiplies it by price to get the usd volume
    public let size: Double
    public let side: Side
    public let liquidation: Bool

    public var quote: Double { price * size }
}

// what an exchange's product endpoints say about the pairs, read once before connecting
public struct Catalog: Sendable {
    var pairs: Set<String> = []
    // contract value of a pair, in base currency or in usd when the pair is inverse
    var multiplier: [String: Double] = [:]
    var inverse: Set<String> = []
    // pairs that live on another socket than the exchange's default one
    var sockets: [String: String] = [:]
    // bybit's own grouping of a pair (innovation, stock, etf, commodity, forex), crypto when missing
    var kinds: [String: String] = [:]

    func toBase(_ pair: String, size: Double, price: Double) -> Double {
        size * (multiplier[pair] ?? 1) / (inverse.contains(pair) ? price : 1)
    }
}

// per websocket memory, a few exchanges need it between messages
public struct SocketState: Sendable {
    let pairs: [String]
    var channels: [Int: String] = [:]
    var seen: Set<Int> = []
    var lastPrice: [String: Double] = [:]
}

public protocol Exchange: Sendable {
    var id: String { get }
    var socketURL: String { get }
    var ping: (message: String, every: Duration)? { get }
    // the pairs this app takes for a coin, "{}" is the coin. a coin gets every one the exchange lists
    var templates: [String] { get }
    // binance and bitstamp name pairs in lowercase
    var lowercase: Bool { get }
    func loadCatalog() async throws -> Catalog
    // index is the position of the pair on its socket, some channels are per socket and not per pair
    func subscriptions(pair: String, index: Int) -> [String]
    // messages that are not trades (acks, heartbeats) give nothing
    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade]
}

// exchanges whose product lists are a few fixed rest urls. aggr reads the same urls through its cors proxy,
// which a browser needs and a native app doesn't, so they're read straight from the exchange
// (the proxy also stalls for 20s+ at times, which froze the app at launch)
protocol RestExchange: Exchange {
    var productURLs: [String] { get }
    func catalog(from responses: [Data]) throws -> Catalog
}

extension RestExchange {
    public func loadCatalog() async throws -> Catalog {
        // all of an exchange's lists at once, kept in productURLs order since catalog(from:) reads them by position
        let responses = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, url) in productURLs.enumerated() {
                group.addTask { (index, try await httpGet(URL(string: url)!)) }
            }
            var byIndex: [Int: Data] = [:]
            for try await (index, data) in group { byIndex[index] = data }
            return productURLs.indices.map { byIndex[$0]! }
        }
        return try catalog(from: responses)
    }
}

extension Exchange {
    public var ping: (message: String, every: Duration)? { nil }
    public var lowercase: Bool { false }

    // the coin a pair belongs to, through the templates
    func coin(of pair: String) -> String? {
        for template in templates {
            let suffix = String(template.dropFirst(2))
            let cased = lowercase ? suffix.lowercased() : suffix
            guard pair.hasSuffix(cased), pair.count > cased.count else { continue }
            let coin = pair.dropLast(cased.count)
            // "AVAX:USD" against "{}USD" leaves "AVAX:", that's the other template's pair
            if coin.allSatisfy({ $0.isLetter || $0.isNumber }) { return coin.uppercased() }
        }
        return nil
    }

    func pairs(for coin: String) -> [String] {
        templates.map { $0.replacingOccurrences(of: "{}", with: lowercase ? coin.lowercased() : coin) }
    }
}

struct ProductError: LocalizedError {
    let errorDescription: String?
}

func require<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw ProductError(errorDescription: "\(what) products unreadable: \(error.localizedDescription)")
    }
}

private struct BinanceInfo: Decodable {
    struct Symbol: Decodable {
        let symbol: String
        let status: String?
        let contractStatus: String?
        let contractSize: Double?
    }
    let symbols: [Symbol]
}

private struct BinanceEvent: Decodable {
    struct Order: Decodable {
        let s: String
        let T: Double
        let p: Num
        let q: Num
        let S: String
    }
    let e: String
    let s: String?
    let T: Double?
    let p: Num?
    let q: Num?
    let m: Bool?
    let o: Order?
}

struct BinanceFutures: RestExchange {
    let id = "BINANCE_FUTURES"
    let productURLs = ["https://fapi.binance.com/fapi/v1/exchangeInfo", "https://dapi.binance.com/dapi/v1/exchangeInfo"]
    let socketURL = "wss://fstream.binance.com/market/ws"
    let templates = ["{}usdt", "{}usd_perp"]
    let lowercase = true

    func catalog(from responses: [Data]) throws -> Catalog {
        var catalog = Catalog()
        for (index, response) in responses.enumerated() {
            for product in try require(BinanceInfo.self, response, id).symbols
            where (product.contractStatus ?? product.status) == "TRADING" {
                let symbol = product.symbol.lowercased()
                catalog.pairs.insert(symbol)
                // coin margined contracts (dapi) are worth a fixed usd amount each
                if index == 1 {
                    catalog.sockets[symbol] = "wss://dstream.binance.com/ws"
                    if let size = product.contractSize {
                        catalog.multiplier[symbol] = size
                        catalog.inverse.insert(symbol)
                    }
                }
            }
        }
        return catalog
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        [#"{"method":"SUBSCRIBE","params":["\#(pair)@aggTrade","\#(pair)@forceOrder"],"id":\#(index + 1)}"#]
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let event = decode(BinanceEvent.self, data) else { return [] }
        if event.e == "aggTrade", let s = event.s, let time = event.T, let price = event.p, let size = event.q, let maker = event.m {
            let pair = s.lowercased()
            return [Trade(market: "\(id):\(pair)", timestamp: time, price: price.value, size: catalog.toBase(pair, size: size.value, price: price.value), side: maker ? .sell : .buy, liquidation: false)]
        }
        if event.e == "forceOrder", let o = event.o {
            let pair = o.s.lowercased()
            return [Trade(market: "\(id):\(pair)", timestamp: o.T, price: o.p.value, size: catalog.toBase(pair, size: o.q.value, price: o.p.value), side: o.S == "BUY" ? .buy : .sell, liquidation: true)]
        }
        return []
    }
}

private struct BitfinexSubscribed: Decodable {
    let event: String
    let chanId: Int?
    let channel: String?
    let pair: String?
}

struct Bitfinex: RestExchange {
    let id = "BITFINEX"
    let productURLs = ["https://api.bitfinex.com/v1/symbols"]
    let socketURL = "wss://api-pub.bitfinex.com/ws/2/"
    // perps only, which bitfinex names like BTCF0:USTF0
    let templates = ["{}F0:USTF0"]

    func catalog(from responses: [Data]) throws -> Catalog {
        Catalog(pairs: Set(try require([String].self, responses[0], id).map { $0.uppercased() }))
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        var messages = [#"{"event":"subscribe","channel":"trades","symbol":"t\#(pair)"}"#]
        if index == 0 { messages.append(#"{"event":"subscribe","channel":"status","key":"liq:global"}"#) }
        return messages
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        if data.first == UInt8(ascii: "{") {
            if let s = decode(BitfinexSubscribed.self, data), s.event == "subscribed", let chanId = s.chanId {
                state.channels[chanId] = s.channel == "trades" ? s.pair : "status"
            }
            return []
        }

        guard let message = decode(JSON.self, data), let chanId = message[0]?.number.map(Int.init),
              let channel = state.channels[chanId], message[1]?.string != "hb"
        else { return [] }

        // the first message of every channel is a snapshot of the past, aggr skips it
        guard state.seen.contains(chanId) else {
            state.seen.insert(chanId)
            return []
        }

        if channel != "status", message[1]?.string == "te",
           let time = message[2]?[1]?.number, let amount = message[2]?[2]?.number, let price = message[2]?[3]?.number {
            state.lastPrice[channel] = price
            return [Trade(market: "\(id):\(channel)", timestamp: time, price: price, size: abs(amount), side: amount < 0 ? .sell : .buy, liquidation: false)]
        }

        guard channel == "status", let entries = message[1]?.array else { return [] }
        return entries.compactMap { entry in
            // liquidations come without a price, aggr uses the last traded price of the pair
            guard let symbol = entry[4]?.string, let amount = entry[5]?.number, let time = entry[2]?.number else { return nil }
            let pair = String(symbol.dropFirst())
            guard !(entry[8]?.truthy ?? false), !(entry[10]?.truthy ?? false), !(entry[11]?.truthy ?? false),
                  state.pairs.contains(pair), let price = state.lastPrice[pair]
            else { return nil }
            return Trade(market: "\(id):\(pair)", timestamp: time, price: price, size: abs(amount), side: amount > 1 ? .sell : .buy, liquidation: true)
        }
    }
}

private struct BybitInstruments: Decodable {
    struct Result: Decodable {
        struct Item: Decodable {
            let symbol: String
            let contractType: String
            // empty for plain crypto, set on the linear list only
            let symbolType: String?
        }
        let list: [Item]
        let nextPageCursor: String?
    }
    let result: Result
}

private struct BybitMessage: Decodable {
    struct Row: Decodable {
        let s: String
        let T: Double
        let p: Num
        let v: Num
        let S: String
    }
    let topic: String
    let data: [Row]
}

struct Bybit: Exchange {
    let id = "BYBIT"
    let socketURL = "wss://stream.bybit.com/v5/public/inverse"
    // usdt perps, usdc perps (BTCPERP) and inverse perps
    let templates = ["{}USDT", "{}PERP", "{}USD"]
    var ping: (message: String, every: Duration)? { (#"{"op":"ping"}"#, .seconds(20)) }

    // aggr's proxy only carries the first page of 500 linear pairs, so bybit is read directly, page by page
    func loadCatalog() async throws -> Catalog {
        // both categories at once, each one page by page
        let lists = try await withThrowingTaskGroup(of: (String, [BybitInstruments.Result.Item]).self) { group in
            for category in ["linear", "inverse"] {
                group.addTask {
                    var items: [BybitInstruments.Result.Item] = []
                    var cursor = ""
                    repeat {
                        var url = URLComponents(string: "https://api.bybit.com/v5/market/instruments-info")!
                        url.queryItems = [URLQueryItem(name: "category", value: category), URLQueryItem(name: "limit", value: "1000")]
                        if !cursor.isEmpty { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
                        let page = try require(BybitInstruments.self, try await httpGet(url.url!), id).result
                        items += page.list
                        cursor = page.nextPageCursor ?? ""
                    } while !cursor.isEmpty
                    return (category, items)
                }
            }
            var lists: [String: [BybitInstruments.Result.Item]] = [:]
            for try await (category, items) in group { lists[category] = items }
            return lists
        }

        var catalog = Catalog()
        // dated futures share the lists, only perpetuals are kept
        for item in lists["linear"]! where item.contractType == "LinearPerpetual" {
            catalog.pairs.insert(item.symbol)
            catalog.sockets[item.symbol] = "wss://stream.bybit.com/v5/public/linear"
            if let kind = item.symbolType, !kind.isEmpty { catalog.kinds[item.symbol] = kind }
        }
        for item in lists["inverse"]! where item.contractType == "InversePerpetual" {
            catalog.pairs.insert(item.symbol)
            catalog.inverse.insert(item.symbol)
        }
        return catalog
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        [#"{"op":"subscribe","args":["publicTrade.\#(pair)","allLiquidation.\#(pair)"]}"#]
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let message = decode(BybitMessage.self, data) else { return [] }
        let liquidation = !message.topic.hasPrefix("publicTrade.")
        return message.data.map { row in
            // a liquidation reported as "Buy" is a long position being closed, aggr flips it
            let buy = liquidation ? row.S != "Buy" : row.S == "Buy"
            return Trade(market: "\(id):\(row.s)", timestamp: row.T, price: row.p.value, size: catalog.toBase(row.s, size: row.v.value, price: row.p.value), side: buy ? .buy : .sell, liquidation: liquidation)
        }
    }
}

private struct DeribitInstruments: Decodable {
    struct Instrument: Decodable {
        let instrument_name: String
        let is_active: Bool
        let future_type: String
    }
    let result: [Instrument]
}

private struct DeribitMessage: Decodable {
    struct Params: Decodable {
        struct Row: Decodable {
            let instrument_name: String
            let timestamp: Double
            let price: Double
            let amount: Double
            let direction: Side
            let liquidation: String?
        }
        let data: [Row]
    }
    let params: Params
}

struct Deribit: RestExchange {
    let id = "DERIBIT"
    let productURLs = [
        "https://www.deribit.com/api/v2/public/get_instruments?currency=BTC&kind=future",
        "https://www.deribit.com/api/v2/public/get_instruments?currency=ETH&kind=future",
        "https://www.deribit.com/api/v2/public/get_instruments?currency=USDC&kind=future"
    ]
    // btc and eth have inverse perps, everything else is a usdc perp
    let templates = ["{}-PERPETUAL", "{}_USDC-PERPETUAL"]
    let socketURL = "wss://www.deribit.com/ws/api/v2"
    var ping: (message: String, every: Duration)? { (#"{"method":"public/ping"}"#, .seconds(45)) }

    func catalog(from responses: [Data]) throws -> Catalog {
        var catalog = Catalog()
        for instrument in try responses.flatMap({ try require(DeribitInstruments.self, $0, id).result }) where instrument.is_active {
            catalog.pairs.insert(instrument.instrument_name)
            if instrument.future_type == "reversed" { catalog.inverse.insert(instrument.instrument_name) }
        }
        return catalog
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        [#"{"method":"public/subscribe","params":{"channels":["trades.\#(pair).100ms"]}}"#]
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let message = decode(DeribitMessage.self, data) else { return [] }
        return message.params.data.map { row in
            Trade(market: "\(id):\(row.instrument_name)", timestamp: row.timestamp, price: row.price, size: catalog.toBase(row.instrument_name, size: row.amount, price: row.price), side: row.direction, liquidation: row.liquidation != nil)
        }
    }
}

private struct OkxInstruments: Decodable {
    struct Instrument: Decodable {
        let instId: String
        let ctVal: Num
        let ctType: String
    }
    let data: [Instrument]
}

private struct OkxMessage: Decodable {
    struct Arg: Decodable { let channel: String }
    struct Row: Decodable {
        struct Detail: Decodable {
            let ts: Num
            let bkPx: Num
            let sz: Num
            let side: Side
        }
        let instId: String
        let ts: Num?
        let px: Num?
        let sz: Num?
        let side: Side?
        let details: [Detail]?
    }
    let arg: Arg
    let data: [Row]
}

struct Okx: RestExchange {
    let id = "OKEX"
    let productURLs = ["https://www.okx.com/api/v5/public/instruments?instType=SWAP"]
    let socketURL = "wss://ws.okx.com:8443/ws/v5/public"
    let templates = ["{}-USDT-SWAP", "{}-USD-SWAP"]

    func catalog(from responses: [Data]) throws -> Catalog {
        var catalog = Catalog()
        for instrument in try require(OkxInstruments.self, responses[0], id).data {
            catalog.pairs.insert(instrument.instId)
            catalog.multiplier[instrument.instId] = instrument.ctVal.value
            if instrument.ctType == "inverse" { catalog.inverse.insert(instrument.instId) }
        }
        return catalog
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        var messages = [#"{"op":"subscribe","args":[{"channel":"trades","instId":"\#(pair)"}]}"#]
        if index == 0 { messages.append(#"{"op":"subscribe","args":[{"channel":"liquidation-orders","instType":"SWAP"}]}"#) }
        return messages
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let message = decode(OkxMessage.self, data) else { return [] }
        switch message.arg.channel {
        case "trades":
            return message.data.compactMap { row in
                guard let ts = row.ts, let px = row.px, let sz = row.sz, let side = row.side else { return nil }
                return Trade(market: "\(id):\(row.instId)", timestamp: ts.value, price: px.value, size: catalog.toBase(row.instId, size: sz.value, price: px.value), side: side, liquidation: false)
            }
        case "liquidation-orders":
            return message.data.filter { state.pairs.contains($0.instId) }.flatMap { row in
                (row.details ?? []).map { detail in
                    Trade(market: "\(id):\(row.instId)", timestamp: detail.ts.value, price: detail.bkPx.value, size: catalog.toBase(row.instId, size: detail.sz.value, price: detail.bkPx.value), side: detail.side, liquidation: true)
                }
            }
        default:
            return []
        }
    }
}

// perp exchanges, in aggr's default order (store/defaultPanes.json). aggr's defaults also had bitmex,
// which shut down, and coinbase, whose perps aren't in the product list aggr's proxy serves
let exchanges: [any Exchange] = [BinanceFutures(), Bitfinex(), Bybit(), Deribit(), Okx()]
