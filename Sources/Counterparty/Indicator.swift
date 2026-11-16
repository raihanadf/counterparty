import CounterpartyKit
import SwiftUI

// aggr's default chart: price candles averaged across markets, volume + delta, liquidations and cvd.
// history comes from aggr's own api, live bars are built from the same trades aggr receives.

private struct SourceBar {
    // nil until the market trades in this bar, a liquidation alone doesn't move the price
    var open: Double?
    var high = 0.0
    var low = 0.0
    var close = 0.0
    var vbuy = 0.0
    var vsell = 0.0
    var lbuy = 0.0
    var lsell = 0.0
}

// what one bar hands to the next, like aggr's renderer sources
private struct Carry {
    var closes: [String: Double] = [:]
    var close: Double?
    var cvd = 0.0
}

// codable because a note keeps the bars around it
struct Point: Codable {
    struct Candle: Codable {
        let open: Double
        let high: Double
        let low: Double
        let close: Double
    }

    let time: Int
    // nil when no market has traded yet
    let candle: Candle?
    let vbuy: Double
    let vsell: Double
    let lbuy: Double
    let lsell: Double
    let cvd: Double
}

// the timeframes the header offers, seconds per bar
let timeframes = [5, 15, 60, 300, 900, 3600, 14400, 86400, 604800]

private let historyBars = 400

@MainActor @Observable
final class IndicatorModel {
    private(set) var error: String?
    // set when aggr keeps no history for any market of the coin
    private(set) var notice: String?
    private(set) var loading = false
    // an older page of history is on its way, asked for when the chart is scrolled to its left edge
    private(set) var loadingOlder = false
    // true once the first history load finished, the dom waits for it so both views start together
    private(set) var ready = false
    // decimals the coin's prices are shown with, known from the first price seen
    private(set) var decimals: Int?

    // the timeframe the bars are in, nil before the first load
    @ObservationIgnored private(set) var timeframe: Int?
    @ObservationIgnored private var buckets: [Int: [String: SourceBar]] = [:]
    // every bar before the live one, already computed
    @ObservationIgnored private var closed: [Point] = []
    @ObservationIgnored private var latest = 0
    @ObservationIgnored private var base = Carry()
    @ObservationIgnored private var token = UUID()
    // trades that land while history loads, replayed on top of it
    @ObservationIgnored private var buffered: [Trade] = []
    @ObservationIgnored private var markets: [String] = []
    // aggr has nothing before the oldest bar, so the chart stops asking
    @ObservationIgnored private var exhausted = false

    // the chart reads this on every frame, only the live bar is recomputed
    var points: [Point] {
        guard let bucket = buckets[latest] else { return closed }
        return closed + [compute(latest, bucket, base).point]
    }

    // the last closed bar's close, what a tab compares its live price against
    var previousClose: Double? {
        closed.last?.candle?.close
    }

    // aggr's server only answers for markets it records, the rest of a coin's markets start from live trades.
    // until is the end of the history asked for: now for the chart, a moment in the past for a note's picture
    func load(timeframe: Int, markets: [String], until to: Date = .now) async {
        let token = UUID()
        self.token = token
        self.timeframe = timeframe
        self.markets = markets
        exhausted = false
        loadingOlder = false
        loading = true
        error = nil
        notice = nil
        buffered = []
        // the old timeframe's bars go now, so they can't be read as the new one's while it loads or after it fails
        buckets = [:]
        closed = []
        latest = 0
        base = Carry()

        do {
            // from a bar's start, so the oldest bar is whole and an older page can end right where it begins
            let from = barStart(Int(to.timeIntervalSince1970), timeframe: timeframe) - timeframe * historyBars
            let history = try await fetchHistory(markets: markets, timeframe: timeframe, from: Date(timeIntervalSince1970: Double(from)), to: to)
            guard token == self.token else { return }
            if history.isEmpty {
                notice = "aggr keeps no history for this coin, the chart builds up from live trades"
            }

            merge(history)
            let cutoff = to.timeIntervalSince1970 * 1000
            loading = false
            ready = true
            if decimals == nil, let close = closed.last?.candle?.close { decimals = Counterparty.decimals(forPrice: close) }
            add(buffered.filter { $0.timestamp >= cutoff })
            buffered = []
        } catch {
            guard token == self.token else { return }
            loading = false
            // a load cut off by a timeframe or tab switch isn't a failure: back to not loaded, to be asked again
            if Task.isCancelled {
                self.timeframe = nil
                buffered = []
                return
            }
            self.error = "history failed: \(error.localizedDescription)"
            ready = true
        }
    }

    // the page of history before the oldest bar, the chart asks when it's scrolled that far back.
    // returns how many bars it put in front, so the chart can stay where it is
    func loadOlder() async -> Int {
        guard !loading, !loadingOlder, !exhausted, let timeframe, let oldest = buckets.keys.min() else { return 0 }
        let token = token
        loadingOlder = true
        defer { if token == self.token { loadingOlder = false } }
        do {
            let from = Date(timeIntervalSince1970: Double(oldest - timeframe * historyBars))
            let history = try await fetchHistory(markets: markets, timeframe: timeframe, from: from, to: Date(timeIntervalSince1970: Double(oldest)))
                .filter { $0.time < oldest }
            guard token == self.token else { return 0 }
            if history.isEmpty {
                exhausted = true
                return 0
            }
            notice = nil
            let before = closed.count
            merge(history)
            return closed.count - before
        } catch {
            guard token == self.token else { return 0 }
            // shown over the chart. the chart asks again when its next bar starts
            notice = "older history failed: \(error.localizedDescription)"
            return 0
        }
    }

    // puts history bars into their buckets and computes every bar before the newest again,
    // the cvd and each bar's open carry over from the bar before
    private func merge(_ history: [HistoryBar]) {
        for bar in history {
            update(bar.time, bar.market) { source in
                if let price = bar.price {
                    source.high = source.open == nil ? price.high : max(source.high, price.high)
                    source.low = source.open == nil ? price.low : min(source.low, price.low)
                    if source.open == nil { source.open = price.open }
                    source.close = price.close
                }
                source.vbuy += bar.vbuy
                source.vsell += bar.vsell
                source.lbuy += bar.lbuy
                source.lsell += bar.lsell
            }
        }
        closed = []
        var carry = Carry()
        let times = buckets.keys.sorted()
        for time in times.dropLast() {
            let bar = compute(time, buckets[time]!, carry)
            closed.append(bar.point)
            carry = bar.next
        }
        base = carry
        latest = times.last ?? 0
    }

    func add(_ trades: [Trade]) {
        if decimals == nil, let first = trades.first(where: { !$0.liquidation }) {
            decimals = Counterparty.decimals(forPrice: first.price)
        }
        // trades that land while history loads are replayed on top of it. before any load they're
        // dropped, the history that comes later already has them
        guard !loading, let timeframe else {
            if loading { buffered += trades }
            return
        }
        for trade in trades {
            var time = barStart(Int(trade.timestamp / 1000), timeframe: timeframe)
            // a late trade from a slower exchange goes into the current bar
            time = max(time, latest)
            if time > latest {
                if let bucket = buckets[latest] {
                    let bar = compute(latest, bucket, base)
                    closed.append(bar.point)
                    base = bar.next
                }
                latest = time
            }
            update(time, trade.market) { source in
                if trade.liquidation {
                    if trade.side == .buy { source.lbuy += trade.quote } else { source.lsell += trade.quote }
                    return
                }
                if source.open == nil {
                    source.open = trade.price
                    source.high = trade.price
                    source.low = trade.price
                }
                source.high = max(source.high, trade.price)
                source.low = min(source.low, trade.price)
                source.close = trade.price
                if trade.side == .buy { source.vbuy += trade.quote } else { source.vsell += trade.quote }
            }
        }
    }

    private func update(_ time: Int, _ market: String, _ change: (inout SourceBar) -> Void) {
        change(&buckets[time, default: [:]][market, default: SourceBar()])
    }

    // one bar of every indicator out of the market bars of a bucket
    private func compute(_ time: Int, _ bucket: [String: SourceBar], _ carry: Carry) -> (point: Point, next: Carry) {
        var closes = carry.closes
        var open = 0.0, high = 0.0, low = 0.0, close = 0.0, sources = 0.0
        var vbuy = 0.0, vsell = 0.0, lbuy = 0.0, lsell = 0.0

        for bar in bucket.values {
            vbuy += bar.vbuy
            vsell += bar.vsell
            lbuy += bar.lbuy
            lsell += bar.lsell
        }

        // markets without trades in this bar still count with their last close (aggr's avg_ohlc)
        for market in Set(closes.keys).union(bucket.keys) {
            if let bar = bucket[market], let barOpen = bar.open {
                open += barOpen
                high += bar.high
                low += bar.low
                close += bar.close
                closes[market] = bar.close
            } else if let last = closes[market] {
                open += last
                high += last
                low += last
                close += last
            } else {
                continue
            }
            sources += 1
        }

        var candle: Point.Candle?
        if sources > 0 {
            let candleOpen = carry.close ?? open / sources
            candle = Point.Candle(open: candleOpen, high: max(candleOpen, high / sources), low: min(candleOpen, low / sources), close: close / sources)
        }
        let next = Carry(closes: closes, close: candle?.close ?? carry.close, cvd: carry.cvd + vbuy - vsell)
        return (Point(time: time, candle: candle, vbuy: vbuy, vsell: vsell, lbuy: lbuy, lsell: lsell, cvd: next.cvd), next)
    }
}

// 1, 2 or 5 times a power of ten, so axis labels land on round prices
func niceStep(_ raw: Double) -> Double {
    let power = pow(10, floor(log10(max(raw, 1e-12))))
    let fraction = raw / power
    return (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * power
}

// about 6 significant digits, so btc shows 1 decimal and a meme coin enough to move
func decimals(forPrice price: Double) -> Int {
    min(12, max(0, 5 - Int(floor(log10(price)))))
}

// 5s, 15m, 4h, 1D, 1W
func timeframeLabel(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return seconds < 604800 ? "\(seconds / 86400)D" : "\(seconds / 604800)W"
}

// fixed english formatting, a locale with comma decimals would make 81.230 read like a decimal
func price(_ value: Double, decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
}

func usd(_ value: Double) -> String {
    let size = abs(value)
    let sign = value < 0 ? "-" : ""
    if size >= 1e9 { return sign + String(format: "%.1fB", size / 1e9) }
    if size >= 1e6 { return sign + String(format: "%.1fM", size / 1e6) }
    if size >= 1e3 { return sign + String(format: "%.0fK", size / 1e3) }
    return sign + String(format: "%.0f", size)
}
