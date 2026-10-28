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

    func load(timeframe: Int) async {
        let token = UUID()
        self.token = token
        self.timeframe = timeframe
        loading = true
        error = nil
        buffered = []

        let to = Date()
        do {
            let history = try await fetchHistory(markets: markets, timeframe: timeframe, from: to.addingTimeInterval(-Double(timeframe * historyBars)), to: to)
            guard token == self.token else { return }

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

// colors from aggr's defaultIndicators.json
private enum Palette {
    static let up = Color(red: 59 / 255, green: 202 / 255, blue: 109 / 255)
    static let down = Color(red: 214 / 255, green: 40 / 255, blue: 40 / 255)
    static let downBorder = Color(red: 239 / 255, green: 67 / 255, blue: 82 / 255)
    static let upWick = Color(red: 223 / 255, green: 211 / 255, blue: 144 / 255)
    static let volumeDown = Color(red: 235 / 255, green: 30 / 255, blue: 47 / 255)
    static let liqBuy = Color(red: 1, green: 76 / 255, blue: 243 / 255)
    static let liqSell = Color(red: 1, green: 183 / 255, blue: 77 / 255)
    static let cvd = Color(red: 59 / 255, green: 202 / 255, blue: 109 / 255)
}

struct IndicatorView: View {
    let model: IndicatorModel
    let timeframe: Int

    @State private var spacing = 7.0
    @State private var zoomStart: Double?
    // bars scrolled back from the live edge
    @State private var offset = 0.0
    @State private var dragStart: Double?
    @State private var hover: CGPoint?

    private let axisWidth = 70.0
    private let axisHeight = 20.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let points = model.points
            Canvas { context, size in
                draw(points, in: &context, size: size)
            }
            .overlay(alignment: .topLeading) { legend(points) }
        }
        .overlay {
            if let error = model.error {
                Text(error).padding(8).background(.red.opacity(0.2), in: .rect(cornerRadius: 4))
            } else if model.loading {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active(let location) = phase { hover = location } else { hover = nil }
        }
        .gesture(
            DragGesture()
                .onChanged { drag in
                    let start = dragStart ?? offset
                    dragStart = start
                    offset = max(0, start + drag.translation.width / spacing)
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { zoom in
                    let start = zoomStart ?? spacing
                    zoomStart = start
                    spacing = min(40, max(2, start * zoom.magnification))
                }
                .onEnded { _ in zoomStart = nil }
        )
        .onTapGesture(count: 2) { offset = 0 }
    }

    // bars on screen, newest last, with their x position
    private func visible(_ points: [Point], width: Double) -> [(x: Double, point: Point)] {
        let count = Int(width / spacing)
        // a few empty bars on the right like trading charts keep
        let end = max(0, points.count - Int(offset))
        let start = max(0, end - count + 3)
        return points[start..<end].enumerated().map { index, point in
            (width - Double(end - start - index + 3) * spacing + spacing / 2, point)
        }
    }

    private func hovered(_ points: [Point], width: Double) -> Point? {
        guard let hover, hover.x < width else { return nil }
        return visible(points, width: width).min { abs($0.x - hover.x) < abs($1.x - hover.x) }?.point
    }

    private func legend(_ points: [Point]) -> some View {
        GeometryReader { geometry in
            let point = hovered(points, width: geometry.size.width - axisWidth) ?? points.last
            if let point, let candle = point.candle {
                VStack(alignment: .leading, spacing: 2) {
                    Text("O \(price(candle.open))  H \(price(candle.high))  L \(price(candle.low))  C \(price(candle.close))")
                        .foregroundStyle(candle.close >= candle.open ? Palette.up : Palette.downBorder)
                    Text("Vol \(usd(point.vbuy + point.vsell))  Δ \(usd(point.vbuy - point.vsell))  CVD \(usd(point.cvd))")
                    Text("Liq ↑\(usd(point.lbuy)) ↓\(usd(point.lsell))").foregroundStyle(Palette.liqSell)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
            }
        }
    }

    private func draw(_ points: [Point], in context: inout GraphicsContext, size: CGSize) {
        let width = size.width - axisWidth
        let height = size.height - axisHeight
        let bars = visible(points, width: width)
        guard width > 0, height > 0, !bars.isEmpty else { return }
        let barWidth = max(1, spacing * 0.7)

        // maps a value into a band of the chart, margins are fractions of the height like lightweight-charts' scaleMargins
        func scale(_ top: Double, _ bottom: Double, _ low: Double, _ high: Double) -> (Double) -> Double {
            let y0 = height * top, y1 = height * (1 - bottom)
            let range = high - low == 0 ? 1 : high - low
            return { y1 - ($0 - low) / range * (y1 - y0) }
        }

        let candles = bars.compactMap { bar in bar.point.candle.map { (bar.x, $0) } }
        guard let low = candles.map(\.1.low).min(), let high = candles.map(\.1.high).max() else { return }
        let y = scale(0.1, 0.25, low, high)

        // price grid and axis
        let step = niceStep((high - low) / 6)
        var level = (low / step).rounded(.up) * step
        while level <= high {
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(level))); $0.addLine(to: CGPoint(x: width, y: y(level))) }, with: .color(.white.opacity(0.05)))
            context.draw(Text(price(level)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: width + 6, y: y(level)), anchor: .leading)
            level += step
        }

        // volume and delta share the bottom band
        let maxVolume = bars.map { $0.point.vbuy + $0.point.vsell }.max() ?? 0
        let volumeY = scale(0.84, 0, 0, maxVolume)
        for (x, point) in bars where maxVolume > 0 {
            let total = point.vbuy + point.vsell
            let delta = point.vbuy - point.vsell
            let rect = CGRect(x: x - barWidth / 2, y: volumeY(total), width: barWidth, height: volumeY(0) - volumeY(total))
            context.fill(Path(rect), with: .color((point.vbuy > point.vsell ? Palette.up : Palette.volumeDown).opacity(0.5)))
            let deltaRect = CGRect(x: x - barWidth / 2, y: volumeY(abs(delta)), width: barWidth, height: volumeY(0) - volumeY(abs(delta)))
            context.fill(Path(deltaRect), with: .color(delta > 0 ? Palette.up : Palette.volumeDown))
        }

        // liquidations, buys up and sells down from a zero line
        let liqHigh = bars.map(\.point.lbuy).max() ?? 0
        let liqLow = -(bars.map(\.point.lsell).max() ?? 0)
        if liqHigh - liqLow > 0 {
            let liqY = scale(0.75, 0.17, liqLow, liqHigh)
            for (x, point) in bars {
                if point.lbuy > 0 {
                    context.fill(Path(CGRect(x: x - barWidth / 2, y: liqY(point.lbuy), width: barWidth, height: liqY(0) - liqY(point.lbuy))), with: .color(Palette.liqBuy))
                }
                if point.lsell > 0 {
                    context.fill(Path(CGRect(x: x - barWidth / 2, y: liqY(0), width: barWidth, height: liqY(-point.lsell) - liqY(0))), with: .color(Palette.liqSell))
                }
            }
        }

        // cumulative volume delta over the volume band
        let cvdValues = bars.map(\.point.cvd)
        let cvdY = scale(0.84, 0, cvdValues.min() ?? 0, cvdValues.max() ?? 0)
        context.stroke(Path { path in
            for (index, bar) in bars.enumerated() {
                let point = CGPoint(x: bar.x, y: cvdY(bar.point.cvd))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }, with: .color(Palette.cvd), lineWidth: 1)

        // candles
        for (x, candle) in candles {
            let up = candle.close >= candle.open
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: y(candle.high))); $0.addLine(to: CGPoint(x: x, y: y(candle.low))) }, with: .color(up ? Palette.upWick : Palette.downBorder))
            let top = y(max(candle.open, candle.close)), bottom = y(min(candle.open, candle.close))
            let body = CGRect(x: x - barWidth / 2, y: top, width: barWidth, height: max(1, bottom - top))
            context.fill(Path(body), with: .color(up ? Palette.up : Palette.down))
            context.stroke(Path(body), with: .color(up ? Palette.up : Palette.downBorder), lineWidth: 0.5)
        }

        // last price line and tag
        if let last = candles.last?.1 {
            let lastY = y(last.close)
            let color = last.close >= last.open ? Palette.up : Palette.down
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: lastY)); $0.addLine(to: CGPoint(x: width, y: lastY)) }, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let tag = CGRect(x: width + 2, y: lastY - 8, width: axisWidth - 4, height: 16)
            context.fill(Path(roundedRect: tag, cornerRadius: 2), with: .color(color))
            context.draw(Text(price(last.close)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white), at: CGPoint(x: tag.midX, y: tag.midY))
        }

        // time axis, a label roughly every 100 points
        let every = max(1, Int(100 / spacing))
        let style = timeframe < 60
            ? Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: .current, calendar: .current)
            : Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current)
        for (x, point) in bars where (point.time / timeframe) % every == 0 {
            let label = Date(timeIntervalSince1970: Double(point.time)).formatted(style)
            context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: x, y: height + axisHeight / 2))
        }

        // crosshair
        if let hover, hover.x < width, hover.y < height {
            let line = StrokeStyle(lineWidth: 1, dash: [3, 3])
            context.stroke(Path { $0.move(to: CGPoint(x: hover.x, y: 0)); $0.addLine(to: CGPoint(x: hover.x, y: height)) }, with: .color(.white.opacity(0.3)), style: line)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: hover.y)); $0.addLine(to: CGPoint(x: width, y: hover.y)) }, with: .color(.white.opacity(0.3)), style: line)
        }
    }
}

// 1, 2 or 5 times a power of ten, so axis labels land on round prices
private func niceStep(_ raw: Double) -> Double {
    let power = pow(10, floor(log10(max(raw, 0.01))))
    let fraction = raw / power
    return (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * power
}

// fixed english formatting, a locale with comma decimals would make 81.230 read like a decimal
func price(_ value: Double) -> String {
    String(format: "%.1f", value)
}

func usd(_ value: Double) -> String {
    let size = abs(value)
    let sign = value < 0 ? "-" : ""
    if size >= 1e6 { return sign + String(format: "%.1fM", size / 1e6) }
    if size >= 1e3 { return sign + String(format: "%.0fK", size / 1e3) }
    return sign + String(format: "%.0f", size)
}
