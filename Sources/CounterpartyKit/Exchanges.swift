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
    // aggr fetches these through its cors proxy, which only accepts these exact urls
    var productURLs: [String] { get }
    var socketURL: String { get }
    var ping: (message: String, every: Duration)? { get }
    func catalog(from responses: [Data]) throws -> Catalog
    // index is the position of the pair on its socket, some channels are per socket and not per pair
    func subscriptions(pair: String, index: Int) -> [String]
    // messages that are not trades (acks, heartbeats) give nothing
    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade]
}

extension Exchange {
    public var ping: (message: String, every: Duration)? { nil }
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
        let permissions: [String]?
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

struct Binance: Exchange {
    let id = "BINANCE"
    let productURLs = ["https://data-api.binance.vision/api/v3/exchangeInfo"]
    let socketURL = "wss://data-stream.binance.vision:9443/ws"

    func catalog(from responses: [Data]) throws -> Catalog {
        var catalog = Catalog()
        for product in try require(BinanceInfo.self, responses[0], id).symbols
        where product.status == "TRADING" && !(product.permissions ?? []).contains("LEVERAGED") {
            catalog.pairs.insert(product.symbol.lowercased())
        }
        return catalog
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        [#"{"method":"SUBSCRIBE","params":["\#(pair)@aggTrade"],"id":\#(index + 1)}"#]
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let event = decode(BinanceEvent.self, data), event.e == "aggTrade",
              let s = event.s, let time = event.T, let price = event.p, let size = event.q, let maker = event.m
        else { return [] }
        return [Trade(market: "\(id):\(s.lowercased())", timestamp: time, price: price.value, size: size.value, side: maker ? .sell : .buy, liquidation: false)]
    }
}

struct BinanceFutures: Exchange {
    let id = "BINANCE_FUTURES"
    let productURLs = ["https://fapi.binance.com/fapi/v1/exchangeInfo", "https://dapi.binance.com/dapi/v1/exchangeInfo"]
    let socketURL = "wss://fstream.binance.com/market/ws"

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

struct Bitfinex: Exchange {
    let id = "BITFINEX"
    let productURLs = ["https://api.bitfinex.com/v1/symbols"]
    let socketURL = "wss://api-pub.bitfinex.com/ws/2/"

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

private struct BitmexInstrument: Decodable {
    let symbol: String
    let isInverse: Bool
    let isQuanto: Bool
    let underlyingToPositionMultiplier: Double?
}

private struct BitmexMessage: Decodable {
    struct Row: Decodable {
        let symbol: String
        let side: String?
        let price: Double?
        let timestamp: String?
        let homeNotional: Double?
        let leavesQty: Double?
    }
    let table: String
    let action: String
    let data: [Row]
}

struct Bitmex: Exchange {
    let id = "BITMEX"
    let productURLs = ["https://www.bitmex.com/api/v1/instrument/active"]
    let socketURL = "wss://www.bitmex.com/realtime"

    func catalog(from responses: [Data]) throws -> Catalog {
        // bitmex shut down, the endpoint now answers with an empty body
        guard !responses[0].isEmpty else { throw ProductError(errorDescription: "www.bitmex.com returned an empty product list") }
        var catalog = Catalog()
        // quanto contracts need the live xbt price to size liquidations, none of aggr's btc markets are quanto
        for product in try require([BitmexInstrument].self, responses[0], id) where !product.isQuanto {
            catalog.pairs.insert(product.symbol)
            if product.isInverse {
                catalog.inverse.insert(product.symbol)
            } else if let multiplier = product.underlyingToPositionMultiplier {
                catalog.multiplier[product.symbol] = 1 / multiplier
            }
        }
        return catalog
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        [#"{"op":"subscribe","args":["trade:\#(pair)","liquidation:\#(pair)"]}"#]
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let message = decode(BitmexMessage.self, data), message.action == "insert",
              message.table == "trade" || message.table == "liquidation"
        else { return [] }
        let liquidation = message.table == "liquidation"
        return message.data.compactMap { row in
            guard let price = row.price else { return nil }
            let size = liquidation ? row.leavesQty.map { catalog.toBase(row.symbol, size: $0, price: price) } : row.homeNotional
            let time = liquidation ? Date().timeIntervalSince1970 * 1000 : row.timestamp.flatMap { milliseconds(iso: $0) }
            guard let size, let time else { return nil }
            return Trade(market: "\(id):\(row.symbol)", timestamp: time, price: price, size: size, side: row.side == "Buy" ? .buy : .sell, liquidation: liquidation)
        }
    }
}

private struct BybitInstruments: Decodable {
    struct Result: Decodable {
        struct Item: Decodable { let symbol: String }
        let list: [Item]
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
    let productURLs = [
        "https://api.bybit.com/v5/market/instruments-info?category=linear",
        "https://api.bybit.com/v5/market/instruments-info?category=inverse"
    ]
    let socketURL = "wss://stream.bybit.com/v5/public/inverse"
    var ping: (message: String, every: Duration)? { (#"{"op":"ping"}"#, .seconds(20)) }

    func catalog(from responses: [Data]) throws -> Catalog {
        var catalog = Catalog()
        for (index, response) in responses.enumerated() {
            for item in try require(BybitInstruments.self, response, id).result.list {
                catalog.pairs.insert(item.symbol)
                if index == 0 {
                    catalog.sockets[item.symbol] = "wss://stream.bybit.com/v5/public/linear"
                } else {
                    catalog.inverse.insert(item.symbol)
                }
            }
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

private struct CoinbaseProducts: Decodable {
    struct Product: Decodable {
        let product_id: String
        let status: String?
        let alias: String?
    }
    let products: [Product]
}

private struct CoinbaseMessage: Decodable {
    struct Event: Decodable {
        struct Row: Decodable {
            let product_id: String
            let price: Num
            let size: Num
            let time: String
            let side: String
        }
        let type: String
        let trades: [Row]?
    }
    let channel: String
    let events: [Event]
}

struct Coinbase: Exchange {
    let id = "COINBASE"
    let productURLs = [
        "https://api.coinbase.com/api/v3/brokerage/market/products?product_type=SPOT",
        "https://api.coinbase.com/api/v3/brokerage/market/products?product_type=FUTURE&contract_expiry_type=PERPETUAL"
    ]
    let socketURL = "wss://advanced-trade-ws.coinbase.com"

    func catalog(from responses: [Data]) throws -> Catalog {
        var catalog = Catalog()
        for product in try require(CoinbaseProducts.self, responses[0], id).products
        where product.status == "online" && (product.alias ?? "").isEmpty {
            catalog.pairs.insert(product.product_id)
        }
        for product in try require(CoinbaseProducts.self, responses[1], id).products {
            catalog.pairs.insert(product.product_id)
        }
        return catalog
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        [#"{"type":"subscribe","channel":"market_trades","product_ids":["\#(pair)"]}"#]
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let message = decode(CoinbaseMessage.self, data), message.channel == "market_trades" else { return [] }
        // snapshots replay old trades, only updates are live. coinbase reports the maker side
        return message.events.filter { $0.type == "update" }.flatMap { $0.trades ?? [] }.compactMap { row in
            guard let time = milliseconds(iso: row.time) else { return nil }
            return Trade(market: "\(id):\(row.product_id)", timestamp: time, price: row.price.value, size: row.size.value, side: row.side == "BUY" ? .sell : .buy, liquidation: false)
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

struct Deribit: Exchange {
    let id = "DERIBIT"
    let productURLs = ["https://www.deribit.com/api/v2/public/get_instruments?currency=BTC&kind=future"]
    let socketURL = "wss://www.deribit.com/ws/api/v2"
    var ping: (message: String, every: Duration)? { (#"{"method":"public/ping"}"#, .seconds(45)) }

    func catalog(from responses: [Data]) throws -> Catalog {
        var catalog = Catalog()
        for instrument in try require(DeribitInstruments.self, responses[0], id).result where instrument.is_active {
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

private struct BitstampMessage: Decodable {
    struct Row: Decodable {
        let microtimestamp: Num
        let price: Num
        let amount: Num
        let type: Int
    }
    let event: String
    let channel: String
    let data: Row
}

struct Bitstamp: Exchange {
    let id = "BITSTAMP"
    let productURLs = ["https://www.bitstamp.net/api/v2/trading-pairs-info/"]
    let socketURL = "wss://ws.bitstamp.net/"

    private struct Pair: Decodable { let url_symbol: String }

    func catalog(from responses: [Data]) throws -> Catalog {
        Catalog(pairs: Set(try require([Pair].self, responses[0], id).map(\.url_symbol)))
    }

    func subscriptions(pair: String, index: Int) -> [String] {
        [#"{"event":"bts:subscribe","data":{"channel":"live_trades_\#(pair)"}}"#]
    }

    func parse(_ data: Data, catalog: Catalog, state: inout SocketState) -> [Trade] {
        guard let message = decode(BitstampMessage.self, data), message.event == "trade", message.data.amount.value != 0,
              let pair = message.channel.split(separator: "_").last
        else { return [] }
        let row = message.data
        return [Trade(market: "\(id):\(pair)", timestamp: (row.microtimestamp.value / 1000).rounded(.down), price: row.price.value, size: row.amount.value, side: row.type == 0 ? .buy : .sell, liquidation: false)]
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

struct Okx: Exchange {
    let id = "OKEX"
    let productURLs = ["https://www.okx.com/api/v5/public/instruments?instType=SWAP"]
    let socketURL = "wss://ws.okx.com:8443/ws/v5/public"

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

let exchanges: [String: any Exchange] = Dictionary(
    uniqueKeysWithValues: ([Binance(), BinanceFutures(), Bitfinex(), Bitmex(), Bybit(), Coinbase(), Deribit(), Bitstamp(), Okx()] as [any Exchange]).map { ($0.id, $0) }
)

// aggr's default btc markets (store/defaultPanes.json)
public let markets = [
    "BINANCE_FUTURES:btcusd_perp",
    "BITFINEX:BTCUSD",
    "BITMEX:XBTUSD",
    "BYBIT:BTCUSD",
    "COINBASE:BTC-USD",
    "DERIBIT:BTC-PERPETUAL",
    "BINANCE:btcusdt",
    "BINANCE_FUTURES:btcusdt",
    "BITFINEX:BTCUST",
    "BITFINEX:BTCF0:USTF0",
    "BITMEX:XBTUSDT",
    "BYBIT:BTCUSDT",
    "COINBASE:BTC-USDT",
    "BITSTAMP:btcusd",
    "OKEX:BTC-USD-SWAP",
    "OKEX:BTC-USDT-SWAP"
]
