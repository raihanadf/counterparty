import AppKit
import SwiftUI

// the chart, with tradingview-style handling (bybit uses tradingview):
// two-finger swipe sideways pans, two-finger swipe up/down or pinch zooms around the pointer,
// dragging pans (and moves the price scale once auto-scale is off), dragging the price axis stretches prices,
// dragging the time axis zooms, double click or a two-finger double tap resets the view.

// how far the chart is zoomed and scrolled
private struct Viewport {
    var spacing = 7.0
    // bars scrolled back from the newest one, fractional while panning, negative looks into empty space on the right
    var offset = 0.0
    // how many bars existed when offset was set, so new bars don't pull a scrolled-back view along
    var anchor = 0
    var autoScale = true
    // price range of the candle area while auto-scale is off
    var range: ClosedRange<Double>?

    func offset(count: Int) -> Double {
        offset > 0 ? offset + Double(count - anchor) : offset
    }
}

// the geometry of one frame, shared by drawing and gestures so they always agree
private struct ChartFrame {
    // empty bars kept right of the newest one
    static let padding = 3.0

    let width: Double
    let height: Double
    let spacing: Double
    let offset: Double
    let count: Int
    let visible: Range<Int>
    // nil when no visible bar has a price yet
    let range: ClosedRange<Double>?

    init(points: [Point], width: Double, height: Double, viewport: Viewport) {
        self.width = width
        self.height = height
        spacing = viewport.spacing
        count = points.count
        offset = viewport.offset(count: points.count)

        // bars back from the newest one at a horizontal position, same formula as barsBack(at:)
        let back = { (x: Double) in (width - x) / viewport.spacing - ChartFrame.padding - 0.5 + viewport.offset(count: points.count) }
        let newest = points.count - 1 - Int(floor(back(width + viewport.spacing)))
        let oldest = points.count - 1 - Int(ceil(back(-viewport.spacing)))
        let first = max(0, oldest), last = min(points.count - 1, newest)
        visible = first <= last ? first..<(last + 1) : 0..<0

        if !viewport.autoScale, let manual = viewport.range {
            range = manual
        } else {
            let candles = points[visible].compactMap(\.candle)
            if let low = candles.map(\.low).min(), let high = candles.map(\.high).max() {
                // a flat range would divide by zero
                range = low < high ? low...high : (low - 1)...(high + 1)
            } else {
                range = nil
            }
        }
    }

    func x(_ index: Int) -> Double {
        width - (Double(count - 1 - index) - offset + ChartFrame.padding + 0.5) * spacing
    }

    // bars from the newest one at a horizontal position, fractional
    func barsBack(at x: Double) -> Double {
        (width - x) / spacing - ChartFrame.padding - 0.5 + offset
    }

    func index(at x: Double) -> Int? {
        let index = count - 1 - Int(barsBack(at: x).rounded())
        return visible.contains(index) ? index : nil
    }

    // candles sit between 10% from the top and 25% from the bottom, like aggr's price scale margins
    var bandTop: Double { height * 0.1 }
    var bandBottom: Double { height * 0.75 }

    func y(_ price: Double, in range: ClosedRange<Double>) -> Double {
        bandBottom - (price - range.lowerBound) / (range.upperBound - range.lowerBound) * (bandBottom - bandTop)
    }

    func price(at y: Double, in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (bandBottom - y) / (bandBottom - bandTop) * (range.upperBound - range.lowerBound)
    }
}

private struct DragState {
    enum Mode {
        case pan, priceScale, timeScale
    }

    let mode: Mode
    let viewport: Viewport
    let range: ClosedRange<Double>?
    let count: Int
}

struct IndicatorView: View {
    let model: IndicatorModel
    let timeframe: Int
    let theme: Theme

    @State private var viewport = Viewport()
    @State private var drag: DragState?
    @State private var hover: CGPoint?

    // hidden axes give their space back to the chart. labels are 7 characters for prices of 1 and up
    // (80000.0, 99.7680), and "0." plus the decimals below that, so the axis grows for small coins
    private var axisWidth: Double {
        guard theme.show.priceAxis else { return 0 }
        let characters = max(7, priceDecimals + 2)
        return max(70, Double(characters) * (theme.font.size - 2) * 0.62 + 16)
    }
    private var axisHeight: Double { theme.show.timeAxis ? 20 : 0 }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let points = model.points
                let frame = frame(points, geometry.size)
                Canvas { context, _ in
                    draw(points, frame, in: &context)
                }
                .overlay(alignment: .topLeading) {
                    if theme.show.legend { legend(points, frame) }
                }
                .overlay {
                    ChartInputView(axisX: frame.width, axisY: frame.height) { input in
                        handle(input, points: points, size: geometry.size)
                    }
                }
                // after the input view so the buttons get their clicks
                .overlay(alignment: .bottomTrailing) {
                    buttons(frame).padding(.trailing, axisWidth + 6).padding(.bottom, axisHeight + 6)
                }
            }
        }
        .overlay {
            if let error = model.error {
                Text(error).foregroundStyle(theme.colors.text.color).padding(8).background(theme.colors.sell.color.opacity(0.2), in: .rect(cornerRadius: 4))
            } else if model.loading {
                ProgressView().controlSize(.small)
            } else if let notice = model.notice {
                Text(notice).font(theme.mono(-1)).foregroundStyle(theme.colors.muted.color)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
                    .allowsHitTesting(false)
            }
        }
    }

    private func frame(_ points: [Point], _ size: CGSize) -> ChartFrame {
        ChartFrame(points: points, width: max(0, size.width - axisWidth), height: max(0, size.height - axisHeight), viewport: viewport)
    }

    // MARK: input

    private func handle(_ input: ChartInput, points: [Point], size: CGSize) {
        let frame = frame(points, size)
        switch input {
        case .hover(let location):
            hover = location

        case .press(let location, let clicks):
            let onPriceAxis = theme.show.priceAxis && location.x > frame.width
            let onTimeAxis = theme.show.timeAxis && location.y > frame.height
            if clicks == 2 {
                if onPriceAxis {
                    viewport.autoScale = true
                    viewport.range = nil
                } else {
                    viewport = Viewport()
                }
                return
            }
            var start = viewport
            start.offset = viewport.offset(count: frame.count)
            start.anchor = frame.count
            drag = DragState(mode: onPriceAxis ? .priceScale : onTimeAxis ? .timeScale : .pan, viewport: start, range: frame.range, count: frame.count)

        case .drag(let translation):
            guard let drag else { return }
            dragged(drag, translation, frame)

        case .release:
            drag = nil

        case .scroll(let dx, let dy, let precise, let location):
            if precise {
                // trackpad: the bigger axis wins so a diagonal swipe doesn't do both
                if abs(dx) > abs(dy) {
                    pan(by: dx / viewport.spacing, frame)
                } else {
                    zoom(by: exp(dy * 0.01), at: location.x, frame)
                }
            } else if dx != 0 {
                // mouse with a horizontal wheel, or shift+wheel which macos turns into horizontal
                pan(by: dx * 2, frame)
            } else {
                zoom(by: exp(dy * 0.1), at: location.x, frame)
            }

        case .pinch(let magnification, let location):
            zoom(by: 1 + magnification, at: location.x, frame)

        case .reset:
            viewport = Viewport()
        }
    }

    private func dragged(_ drag: DragState, _ translation: CGSize, _ frame: ChartFrame) {
        switch drag.mode {
        case .pan:
            viewport.offset = clamp(offset: drag.viewport.offset + translation.width / drag.viewport.spacing, frame)
            viewport.anchor = frame.count

            // a mostly sideways drag shouldn't knock the price scale out of auto
            let threshold = drag.viewport.autoScale ? 20.0 : 0
            guard abs(translation.height) > threshold, let range = drag.range else { return }
            let moved = translation.height - threshold * (translation.height > 0 ? 1 : -1)
            let perPoint = (range.upperBound - range.lowerBound) / (frame.bandBottom - frame.bandTop)
            viewport.autoScale = false
            viewport.range = (range.lowerBound + moved * perPoint)...(range.upperBound + moved * perPoint)

        case .priceScale:
            guard let range = drag.range else { return }
            // dragging down squeezes the candles, up stretches them
            let half = (range.upperBound - range.lowerBound) / 2 * exp(translation.height * 0.005)
            let middle = (range.lowerBound + range.upperBound) / 2
            viewport.autoScale = false
            viewport.range = (middle - half)...(middle + half)

        case .timeScale:
            viewport.spacing = clamp(spacing: drag.viewport.spacing * exp(translation.width * 0.005))
        }
    }

    private func pan(by bars: Double, _ frame: ChartFrame) {
        viewport.offset = clamp(offset: frame.offset + bars, frame)
        viewport.anchor = frame.count
    }

    // keeps the bar under the pointer where it is
    private func zoom(by factor: Double, at x: Double, _ frame: ChartFrame) {
        let barsBack = frame.barsBack(at: x)
        viewport.spacing = clamp(spacing: viewport.spacing * factor)
        let offset = barsBack - (frame.width - x) / viewport.spacing + ChartFrame.padding + 0.5
        viewport.offset = clamp(offset: offset, frame)
        viewport.anchor = frame.count
    }

    private func clamp(spacing: Double) -> Double {
        min(60, max(1.5, spacing))
    }

    // half a screen of empty space on the right at most, and the oldest bar stays on screen
    private func clamp(offset: Double, _ frame: ChartFrame) -> Double {
        let screen = frame.width / viewport.spacing
        return min(max(0, Double(frame.count) - 5), max(-screen / 2, offset))
    }

    // MARK: overlays

    private func legend(_ points: [Point], _ frame: ChartFrame) -> some View {
        let index = hover.flatMap { $0.x < frame.width ? frame.index(at: $0.x) : nil } ?? points.indices.last
        return VStack(alignment: .leading, spacing: 2) {
            if let index, let candle = points[index].candle {
                let point = points[index]
                Text("\(timeLabel(point.time))  O \(price(candle.open))  H \(price(candle.high))  L \(price(candle.low))  C \(price(candle.close))")
                    .foregroundStyle((candle.close >= candle.open ? theme.colors.candleUp : theme.colors.candleDownBorder).color)
                Text("Vol \(usd(point.vbuy + point.vsell))  Δ \(usd(point.vbuy - point.vsell))  CVD \(usd(point.cvd))")
                    .foregroundStyle(theme.colors.text.color)
                Text("Liq ↑\(usd(point.lbuy)) ↓\(usd(point.lsell))").foregroundStyle(theme.colors.liquidationSell.color)
            }
        }
        .font(theme.mono(-1))
        .padding(8)
        .allowsHitTesting(false)
    }

    // tradingview's corner buttons: auto-scale, and back to the newest bar when scrolled away
    private func buttons(_ frame: ChartFrame) -> some View {
        HStack(spacing: 4) {
            if frame.offset > 1 {
                Button {
                    viewport.offset = 0
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .help("Scroll to the newest bar")
            }
            Button {
                viewport.autoScale.toggle()
                viewport.range = nil
            } label: {
                Text("A").fontWeight(.semibold)
            }
            .foregroundStyle((viewport.autoScale ? theme.colors.accent : theme.colors.muted).color)
            .help(viewport.autoScale ? "Auto-scale is on, drag the price axis to scale by hand" : "Turn auto-scale back on")
        }
        .buttonStyle(.borderless)
        .font(theme.mono(-1))
        .foregroundStyle(theme.colors.text.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.colors.panel.color.opacity(0.9), in: .rect(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.colors.border.color))
    }

    private func timeLabel(_ time: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(time))
        let style = timeframe < 60
            ? Date.VerbatimFormatStyle(format: "\(day: .twoDigits) \(month: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", locale: Locale(identifier: "en_US"), timeZone: .current, calendar: .current)
            : Date.VerbatimFormatStyle(format: "\(day: .twoDigits) \(month: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", locale: Locale(identifier: "en_US"), timeZone: .current, calendar: .current)
        return date.formatted(style)
    }

    // MARK: drawing

    private func draw(_ points: [Point], _ frame: ChartFrame, in context: inout GraphicsContext) {
        let colors = theme.colors
        let show = theme.show
        let width = frame.width
        let height = frame.height
        guard width > 0, height > 0, !frame.visible.isEmpty else { return }
        let bars = frame.visible.map { (x: frame.x($0), point: points[$0]) }
        let barWidth = max(1, frame.spacing * theme.layout.candleWidth)
        let line = { (from: CGPoint, to: CGPoint) in Path { $0.move(to: from); $0.addLine(to: to) } }

        // maps a value into a band of the chart, margins are fractions of the height like lightweight-charts' scaleMargins
        func scale(_ top: Double, _ bottom: Double, _ low: Double, _ high: Double) -> (Double) -> Double {
            let y0 = height * top, y1 = height * (1 - bottom)
            let range = high - low == 0 ? 1 : high - low
            return { y1 - ($0 - low) / range * (y1 - y0) }
        }

        // everything is clipped to the plot so panned bars don't spill onto the axes
        var plot = context
        plot.clip(to: Path(CGRect(x: 0, y: 0, width: width, height: height)))

        // volume and delta share the bottom band
        let maxVolume = bars.map { $0.point.vbuy + $0.point.vsell }.max() ?? 0
        let volumeY = scale(0.84, 0, 0, maxVolume)
        for (x, point) in bars where maxVolume > 0 {
            let total = point.vbuy + point.vsell
            let delta = point.vbuy - point.vsell
            if show.volume {
                let rect = CGRect(x: x - barWidth / 2, y: volumeY(total), width: barWidth, height: volumeY(0) - volumeY(total))
                plot.fill(Path(rect), with: .color((point.vbuy > point.vsell ? colors.volumeUp : colors.volumeDown).color))
            }
            if show.delta {
                let rect = CGRect(x: x - barWidth / 2, y: volumeY(abs(delta)), width: barWidth, height: volumeY(0) - volumeY(abs(delta)))
                plot.fill(Path(rect), with: .color((delta > 0 ? colors.deltaUp : colors.deltaDown).color))
            }
        }

        // liquidations, buys up and sells down from a zero line
        let liqHigh = bars.map(\.point.lbuy).max() ?? 0
        let liqLow = -(bars.map(\.point.lsell).max() ?? 0)
        if show.liquidations && liqHigh - liqLow > 0 {
            let liqY = scale(0.75, 0.17, liqLow, liqHigh)
            for (x, point) in bars {
                if point.lbuy > 0 {
                    plot.fill(Path(CGRect(x: x - barWidth / 2, y: liqY(point.lbuy), width: barWidth, height: liqY(0) - liqY(point.lbuy))), with: .color(colors.liquidationBuy.color))
                }
                if point.lsell > 0 {
                    plot.fill(Path(CGRect(x: x - barWidth / 2, y: liqY(0), width: barWidth, height: liqY(-point.lsell) - liqY(0))), with: .color(colors.liquidationSell.color))
                }
            }
        }

        // cumulative volume delta over the volume band
        if show.cvd {
            let cvdValues = bars.map(\.point.cvd)
            let cvdY = scale(0.84, 0, cvdValues.min() ?? 0, cvdValues.max() ?? 0)
            plot.stroke(Path { path in
                for (index, bar) in bars.enumerated() {
                    let point = CGPoint(x: bar.x, y: cvdY(bar.point.cvd))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }, with: .color(colors.cvd.color), lineWidth: 1)
        }

        guard let range = frame.range else { return }
        let y = { (price: Double) in frame.y(price, in: range) }

        // price grid and axis labels, about one line every 60 points
        let step = niceStep((range.upperBound - range.lowerBound) / max(2, (frame.bandBottom - frame.bandTop) / 60))
        var level = (frame.price(at: height, in: range) / step).rounded(.up) * step
        while y(level) >= 0 {
            if show.grid {
                plot.stroke(line(CGPoint(x: 0, y: y(level)), CGPoint(x: width, y: y(level))), with: .color(colors.grid.color))
            }
            if show.priceAxis && y(level) < height - 8 && y(level) > 8 {
                context.draw(Text(price(level)).font(theme.mono(-2)).foregroundStyle(colors.muted.color), at: CGPoint(x: width + 6, y: y(level)), anchor: .leading)
            }
            level += step
        }

        if show.candles {
            for (x, point) in bars {
                guard let candle = point.candle else { continue }
                let up = candle.close >= candle.open
                plot.stroke(line(CGPoint(x: x, y: y(candle.high)), CGPoint(x: x, y: y(candle.low))), with: .color((up ? colors.wickUp : colors.wickDown).color))
                let top = y(max(candle.open, candle.close)), bottom = y(min(candle.open, candle.close))
                let body = CGRect(x: x - barWidth / 2, y: top, width: barWidth, height: max(1, bottom - top))
                plot.fill(Path(body), with: .color((up ? colors.candleUp : colors.candleDown).color))
                plot.stroke(Path(body), with: .color((up ? colors.candleUpBorder : colors.candleDownBorder).color), lineWidth: 0.5)
            }
        }

        // last price line, and its tag on the price axis, even when the newest bar is scrolled off screen
        if let last = points.last?.candle {
            let lastY = y(last.close)
            let color = (last.close >= last.open ? colors.candleUp : colors.candleDown).color
            if show.lastPriceLine {
                plot.stroke(line(CGPoint(x: 0, y: lastY), CGPoint(x: width, y: lastY)), with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if show.priceAxis && lastY > -8 && lastY < height + 8 {
                tag(price(last.close), at: CGPoint(x: width + 2, y: lastY), fill: color, text: colors.priceTagText.color, in: &context)
            }
        }

        // time axis, a label roughly every 100 points on round bar times
        if show.timeAxis {
            let every = max(1, Int(100 / frame.spacing))
            let style = timeframe < 60
                ? Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: .current, calendar: .current)
                : Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current)
            for (x, point) in bars where (point.time / timeframe) % every == 0 && x > 20 && x < width - 20 {
                let label = Date(timeIntervalSince1970: Double(point.time)).formatted(style)
                context.draw(Text(label).font(theme.mono(-2)).foregroundStyle(colors.muted.color), at: CGPoint(x: x, y: height + axisHeight / 2))
            }
        }

        // crosshair snaps to the hovered bar, with its price and time on the axes
        if show.crosshair, drag == nil, let hover, hover.x < width, hover.y < height, let index = frame.index(at: hover.x) {
            let x = frame.x(index)
            let dash = StrokeStyle(lineWidth: 1, dash: [3, 3])
            plot.stroke(line(CGPoint(x: x, y: 0), CGPoint(x: x, y: height)), with: .color(colors.crosshair.color), style: dash)
            plot.stroke(line(CGPoint(x: 0, y: hover.y), CGPoint(x: width, y: hover.y)), with: .color(colors.crosshair.color), style: dash)
            if show.priceAxis {
                tag(price(frame.price(at: hover.y, in: range)), at: CGPoint(x: width + 2, y: hover.y), fill: colors.panel.color, text: colors.text.color, border: colors.border.color, in: &context)
            }
            if show.timeAxis {
                let label = Text(timeLabel(points[index].time)).font(theme.mono(-2)).foregroundStyle(colors.text.color)
                let size = context.resolve(label).measure(in: CGSize(width: 300, height: 30))
                let box = CGRect(x: min(max(0, x - size.width / 2 - 6), width - size.width - 12), y: height + 2, width: size.width + 12, height: axisHeight - 4)
                context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(colors.panel.color))
                context.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(colors.border.color))
                context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
            }
        }
    }

    // a price label box on the price axis
    private func tag(_ text: String, at point: CGPoint, fill: Color, text color: Color, border: Color? = nil, in context: inout GraphicsContext) {
        let box = CGRect(x: point.x, y: point.y - 8, width: axisWidth - 4, height: 16)
        context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(fill))
        if let border { context.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(border)) }
        context.draw(Text(text).font(theme.mono(-2, weight: .semibold)).foregroundStyle(color), at: CGPoint(x: box.midX, y: box.midY))
    }
}

// MARK: appkit input

private enum ChartInput {
    case hover(CGPoint?)
    case press(CGPoint, clicks: Int)
    case drag(CGSize)
    case release
    case scroll(dx: Double, dy: Double, precise: Bool, at: CGPoint)
    case pinch(Double, at: CGPoint)
    case reset
}

// swiftui doesn't see scroll wheels, trackpad swipes or pinches anchored at the pointer on macos, so a plain nsview catches them
private struct ChartInputView: NSViewRepresentable {
    // where the price axis and the time axis start, for the cursors
    let axisX: Double
    let axisY: Double
    let send: (ChartInput) -> Void

    func makeNSView(context: Context) -> InputView {
        InputView()
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.send = send
        view.axisX = axisX
        view.axisY = axisY
    }

    final class InputView: NSView {
        var send: (ChartInput) -> Void = { _ in }
        var axisX = 0.0
        var axisY = 0.0
        private var pressed: CGPoint?

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }

        private func location(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        private func cursor(at point: CGPoint) -> NSCursor {
            point.x > axisX ? .resizeUpDown : point.y > axisY ? .resizeLeftRight : .crosshair
        }

        override func mouseMoved(with event: NSEvent) {
            cursor(at: location(event)).set()
            send(.hover(location(event)))
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
            send(.hover(nil))
        }

        override func mouseDown(with event: NSEvent) {
            let point = location(event)
            pressed = point
            if point.x <= axisX && point.y <= axisY { NSCursor.closedHand.set() }
            send(.press(point, clicks: event.clickCount))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressed else { return }
            let point = location(event)
            send(.drag(CGSize(width: point.x - pressed.x, height: point.y - pressed.y)))
        }

        override func mouseUp(with event: NSEvent) {
            pressed = nil
            cursor(at: location(event)).set()
            send(.release)
            send(.hover(location(event)))
        }

        override func scrollWheel(with event: NSEvent) {
            send(.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, at: location(event)))
        }

        override func magnify(with event: NSEvent) {
            send(.pinch(event.magnification, at: location(event)))
        }

        override func smartMagnify(with event: NSEvent) {
            send(.reset)
        }
    }
}
