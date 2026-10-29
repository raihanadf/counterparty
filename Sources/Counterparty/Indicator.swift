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

struct Point {
    let time: Int
    // nil when no market has traded yet
    let candle: (open: Double, high: Double, low: Double, close: Double)?
    let vbuy: Double
    let vsell: Double
    let lbuy: Double
    let lsell: Double
    let cvd: Double
}

private let historyBars = 400

@MainActor @Observable
final class IndicatorModel {
    private(set) var error: String?
    // set when aggr keeps no history for any market of the coin
    private(set) var notice: String?
    private(set) var loading = false

    @ObservationIgnored private var timeframe = 60
    @ObservationIgnored private var buckets: [Int: [String: SourceBar]] = [:]
    // every bar before the live one, already computed
    @ObservationIgnored private var closed: [Point] = []
    @ObservationIgnored private var latest = 0
    @ObservationIgnored private var base = Carry()
    @ObservationIgnored private var token = UUID()
    // trades that land while history loads, replayed on top of it
    @ObservationIgnored private var buffered: [Trade] = []

    // the chart reads this on every frame, only the live bar is recomputed
    var points: [Point] {
        guard let bucket = buckets[latest] else { return closed }
        return closed + [compute(latest, bucket, base).point]
    }

    // aggr's server only answers for markets it records, the rest of a coin's markets start from live trades
    func load(timeframe: Int, markets: [String]) async {
        let token = UUID()
        self.token = token
        self.timeframe = timeframe
        loading = true
        error = nil
        notice = nil
        buffered = []

        let to = Date()
        do {
            let history = try await fetchHistory(markets: markets, timeframe: timeframe, from: to.addingTimeInterval(-Double(timeframe * historyBars)), to: to)
            guard token == self.token else { return }
            if history.isEmpty {
                notice = "aggr keeps no history for this coin, the chart builds up from live trades"
            }

            buckets = [:]
            for bar in history {
                update(bar.time, bar.market) { source in
                    source.high = source.open == nil ? bar.high : max(source.high, bar.high)
                    source.low = source.open == nil ? bar.low : min(source.low, bar.low)
                    if source.open == nil { source.open = bar.open }
                    source.close = bar.close
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
            let cutoff = to.timeIntervalSince1970 * 1000
            loading = false
            add(buffered.filter { $0.timestamp >= cutoff })
            buffered = []
        } catch {
            guard token == self.token else { return }
            self.error = "history failed: \(error.localizedDescription)"
            loading = false
        }
    }

    func add(_ trades: [Trade]) {
        if loading {
            buffered += trades
            return
        }
        for trade in trades {
            var time = Int(trade.timestamp / 1000)
            time -= time % timeframe
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

        var candle: (open: Double, high: Double, low: Double, close: Double)?
        if sources > 0 {
            let candleOpen = carry.close ?? open / sources
            candle = (candleOpen, max(candleOpen, high / sources), min(candleOpen, low / sources), close / sources)
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

// decimals for the selected coin: about 6 significant digits, so btc shows 1 and a meme coin enough to move.
// one coin is shown at a time and the store sets this when the coin's price is known, so a global is enough
nonisolated(unsafe) var priceDecimals = 1

func decimals(forPrice price: Double) -> Int {
    min(12, max(0, 5 - Int(floor(log10(price)))))
}

// fixed english formatting, a locale with comma decimals would make 81.230 read like a decimal
func price(_ value: Double) -> String {
    String(format: "%.\(priceDecimals)f", value)
}

func usd(_ value: Double) -> String {
    let size = abs(value)
    let sign = value < 0 ? "-" : ""
    if size >= 1e6 { return sign + String(format: "%.1fM", size / 1e6) }
    if size >= 1e3 { return sign + String(format: "%.0fK", size / 1e3) }
    return sign + String(format: "%.0f", size)
}
