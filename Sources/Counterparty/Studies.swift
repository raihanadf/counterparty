import CounterpartyKit
import Foundation

// the lines drawn over the chart, one value per bar, nil where a line has nothing to say yet.
// an empty line isn't drawn at all
struct Studies {
    var vwap: [Double?] = []
    var anchored: [Double?] = []
    var rsi: [Double?] = []
}

// volume weighted average price: the dollars traded since an anchor divided by the coins they bought,
// which is what the average buyer since then paid. anchor gives the start a bar counts from, the start
// of its utc day for the session vwap or one fixed moment for an anchored one, and the bar holding the
// anchor is the first to count.
// when the bars start after their anchor, the part before them comes from coarser bars of the same coin:
// those count up to their first boundary inside the finer bars, and the finer bars take over from there.
// without coarse bars reaching back to the anchor, that stretch stays nil instead of showing a wrong line
func vwap(_ points: [Point], timeframe: Int, coarse: [Point], coarseTimeframe: Int, anchor: (Int) -> Int) -> [Double?] {
    var values = [Double?](repeating: nil, count: points.count)
    var current: Int?
    var dollars = 0.0, coins = 0.0
    // bars before this time are left out, the coarse bars already counted them. nil while the stretch can't be computed
    var from: Int? = 0
    let count = { (point: Point) in
        guard let candle = point.candle else { return }
        let volume = point.vbuy + point.vsell
        dollars += volume
        coins += volume / ((candle.high + candle.low + candle.close) / 3)
    }
    for (index, point) in points.enumerated() {
        let start = anchor(point.time)
        // the anchor is still ahead of this bar
        if point.time + timeframe <= start { continue }
        if start != current {
            current = start
            dollars = 0
            coins = 0
            from = 0
            // the first bar there is, and the anchor was before it
            if index == 0 && point.time > start {
                let boundary = barStart(point.time, timeframe: coarseTimeframe)
                let handover = boundary == point.time ? boundary : boundary + coarseTimeframe
                if let first = coarse.first, first.time <= start {
                    for bar in coarse where bar.time + coarseTimeframe > start && bar.time < handover { count(bar) }
                    from = handover
                } else {
                    from = nil
                }
            }
        }
        guard let from, point.time >= from else { continue }
        count(point)
        if coins > 0 { values[index] = dollars / coins }
    }
    return values
}

// wilder's relative strength index over closes: 100 when every bar of the period closed up, 0 when every one closed down
func rsi(_ points: [Point], period: Int = 14) -> [Double?] {
    var values = [Double?](repeating: nil, count: points.count)
    var previous: Double?
    var gain = 0.0, loss = 0.0
    var changes = 0
    for (index, point) in points.enumerated() {
        guard let close = point.candle?.close else { continue }
        defer { previous = close }
        guard let previous else { continue }
        let change = close - previous
        changes += 1
        if changes <= period {
            // the first average is a plain mean of the period's gains and losses
            gain += max(change, 0) / Double(period)
            loss += max(-change, 0) / Double(period)
            if changes < period { continue }
        } else {
            gain = (gain * Double(period - 1) + max(change, 0)) / Double(period)
            loss = (loss * Double(period - 1) + max(-change, 0)) / Double(period)
        }
        values[index] = gain + loss == 0 ? 50 : 100 * gain / (gain + loss)
    }
    return values
}
