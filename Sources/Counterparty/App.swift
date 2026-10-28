import AppKit
import CounterpartyKit
import SwiftUI

@MainActor @Observable
final class MarketStore {
    let indicator = IndicatorModel()
    let dom = DomModel()
    private(set) var statuses: [String: MarketStatus] = [:]
    // trade counts and last price change on every trade, views poll them instead of observing
    @ObservationIgnored private(set) var counts: [String: Int] = [:]
    @ObservationIgnored private(set) var lastPrice: Double?
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        startFeed(
            markets: markets,
            onTrades: { [weak self] trades in self?.receive(trades) },
            onStatus: { [weak self] markets, status in
                for market in markets { self?.statuses[market] = status }
            }
        )
    }

    private func receive(_ trades: [Trade]) {
        for trade in trades where !trade.liquidation {
            counts[trade.market, default: 0] += 1
            lastPrice = trade.price
        }
        indicator.add(trades)
        dom.add(trades)
    }
}

@main
struct CounterpartyApp: App {
    @State private var store = MarketStore()

    init() {
        // a bare executable (swift run) starts as a background process without this
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Counterparty", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
                .task {
                    NSApplication.shared.activate()
                    store.start()
                }
        }
        .defaultSize(width: 1400, height: 860)
    }
}

struct ContentView: View {
    let store: MarketStore

    // toggles and selections survive a relaunch
    @AppStorage("showIndicator") private var showIndicator = true
    @AppStorage("showDom") private var showDom = true
    @AppStorage("timeframe") private var timeframe = 60
    @AppStorage("tick") private var tick = 10

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if showIndicator {
                    IndicatorView(model: store.indicator, timeframe: timeframe)
                }
                if showIndicator && showDom {
                    Divider()
                }
                if showDom {
                    DomView(model: store.dom, tick: tick)
                        .frame(width: showIndicator ? 440 : nil)
                }
                if !showIndicator && !showDom {
                    Text("Both views are off. Turn on Indicator or DOM.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            MarketsBar(store: store)
        }
        .task(id: timeframe) { await store.indicator.load(timeframe: timeframe) }
    }

    private var header: some View {
        HStack(spacing: 18) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(store.lastPrice.map(price) ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 90, alignment: .leading)
            }
            Text("BTC · aggr markets").foregroundStyle(.secondary)
            Spacer()
            Toggle("Indicator", isOn: $showIndicator).toggleStyle(.switch)
            Picker("Timeframe", selection: $timeframe) {
                Text("5s").tag(5)
                Text("15s").tag(15)
                Text("1m").tag(60)
                Text("5m").tag(300)
                Text("15m").tag(900)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!showIndicator)
            Divider().frame(height: 18)
            Toggle("DOM", isOn: $showDom).toggleStyle(.switch)
            Picker("Row size", selection: $tick) {
                ForEach([1, 5, 10, 25, 50, 100], id: \.self) { Text("$\($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!showDom)
            Button("Reset DOM") { store.dom.reset() }
                .disabled(!showDom)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// connection state and trade count per market, to compare against aggr
struct MarketsBar: View {
    let store: MarketStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            FlowLayout {
                ForEach(markets, id: \.self) { market in
                    let status = store.statuses[market] ?? .loading
                    let count = store.counts[market]
                    HStack(spacing: 5) {
                        Circle().fill(color(status, live: count != nil)).frame(width: 7, height: 7)
                        Text(market).foregroundStyle(.secondary)
                        Text("\(count ?? 0)")
                    }
                    .help(describe(status))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func color(_ status: MarketStatus, live: Bool) -> Color {
        switch status {
        case .open: live ? .green : .orange
        case .loading, .connecting: .orange
        case .down, .unavailable: .red
        }
    }

    private func describe(_ status: MarketStatus) -> String {
        switch status {
        case .loading: "loading products"
        case .connecting: "connecting"
        case .open: "open"
        case .down(let reason): "down: \(reason)"
        case .unavailable(let reason): "unavailable: \(reason)"
        }
    }
}

// wraps the market chips onto as many lines as the window needs
struct FlowLayout: Layout {
    var spacing = 14.0
    var lineSpacing = 4.0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x = 0.0, y = 0.0, line = 0.0, widest = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
