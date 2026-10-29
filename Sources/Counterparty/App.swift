import AppKit
import CounterpartyKit
import SwiftUI

@MainActor @Observable
final class MarketStore {
    let indicator = IndicatorModel()
    let dom = DomModel()
    // nil until every exchange's product list is read
    private(set) var catalogs: Catalogs?
    private(set) var coins: [Coin] = []
    private(set) var coin: String
    private(set) var markets: [String] = []
    private(set) var statuses: [String: MarketStatus] = [:]
    var choosingCoin = false
    // what the header and the market bar show, copied from the live values twice a second
    private(set) var price: Double?
    private(set) var tradeCounts: [String: Int] = [:]
    // these change on every trade, observing them would redraw the window per trade
    @ObservationIgnored private var counts: [String: Int] = [:]
    @ObservationIgnored private var lastPrice: Double?
    @ObservationIgnored private var feed: Task<Void, Never>?
    // trades and statuses from the previous coin's sockets can still land after a switch
    @ObservationIgnored private var generation = 0

    init() {
        UserDefaults.standard.register(defaults: [Keys.coin: "BTC"])
        coin = UserDefaults.standard.string(forKey: Keys.coin)!
    }

    func start() async {
        guard catalogs == nil else { return }
        // the store lives as long as the app, so does this
        Task {
            while true {
                if price != lastPrice { price = lastPrice }
                if tradeCounts != counts { tradeCounts = counts }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let catalogs = await loadCatalogs()
        self.catalogs = catalogs
        coins = catalogs.coins
        select(coin)
    }

    func select(_ symbol: String) {
        guard let catalogs else { return }
        coin = symbol
        UserDefaults.standard.set(symbol, forKey: Keys.coin)
        feed?.cancel()
        generation += 1
        let generation = generation

        markets = catalogs.markets(for: symbol)
        statuses = [:]
        counts = [:]
        lastPrice = nil
        dom.clear()
        feed = startFeed(
            markets: markets,
            catalogs: catalogs,
            onTrades: { [weak self] trades in
                guard let self, self.generation == generation else { return }
                receive(trades)
            },
            onStatus: { [weak self] markets, status in
                guard let self, self.generation == generation else { return }
                for market in markets { statuses[market] = status }
            }
        )
    }

    func loadHistory(timeframe: Int) async {
        await indicator.load(timeframe: timeframe, markets: markets)
        if lastPrice == nil, let close = indicator.points.last?.candle?.close {
            priceDecimals = decimals(forPrice: close)
        }
    }

    private func receive(_ trades: [Trade]) {
        if lastPrice == nil, let first = trades.first(where: { !$0.liquidation }) {
            priceDecimals = decimals(forPrice: first.price)
        }
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
    @State private var themes = ThemeStore()

    init() {
        // a bare executable (swift run) starts as a background process without this
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Counterparty", id: "main") {
            ContentView(store: store, themes: themes)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    NSApplication.shared.activate()
                    await store.start()
                }
        }
        .defaultSize(width: 1400, height: 860)
        .commands { ViewCommands(store: store) }

        Settings {
            SettingsView(themes: themes)
        }
    }
}

// toggles and selections survive a relaunch
private enum Keys {
    static let showIndicator = "showIndicator"
    static let showDom = "showDom"
    static let timeframe = "timeframe"
    static let tick = "tick"
    static let coin = "coin"
}

private let timeframes = [(5, "5s"), (15, "15s"), (60, "1m"), (300, "5m"), (900, "15m")]
// multiples of the dom's unit, so $1 to $100 for btc and $0.01 to $1 for sol
private let ticks = [1, 5, 10, 25, 50, 100]

private func rowSize(_ tick: Int, unit: Double?) -> String {
    guard let unit else { return "\(tick)×" }
    // as many decimals as the unit has, $0.025 stays $0.025
    let digits = max(0, -Int(log10(unit).rounded()))
    return "$" + (Double(tick) * unit).formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
}

// the same switches as the header, so they stay reachable when a theme hides it
struct ViewCommands: Commands {
    let store: MarketStore

    @AppStorage(Keys.showIndicator) private var showIndicator = true
    @AppStorage(Keys.showDom) private var showDom = true
    @AppStorage(Keys.timeframe) private var timeframe = 60
    @AppStorage(Keys.tick) private var tick = 10

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Choose Coin…") { store.choosingCoin = true }.keyboardShortcut("k")
            Toggle("Indicator", isOn: $showIndicator).keyboardShortcut("1")
            Toggle("DOM", isOn: $showDom).keyboardShortcut("2")
            Picker("Timeframe", selection: $timeframe) {
                ForEach(timeframes, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("DOM Row Size", selection: $tick) {
                ForEach(ticks, id: \.self) { Text(rowSize($0, unit: store.dom.unit)).tag($0) }
            }
            Button("Reset DOM") { store.dom.reset() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
        }
    }
}

struct ContentView: View {
    let store: MarketStore
    let themes: ThemeStore

    @AppStorage(Keys.showIndicator) private var showIndicator = true
    @AppStorage(Keys.showDom) private var showDom = true
    @AppStorage(Keys.timeframe) private var timeframe = 60
    @AppStorage(Keys.tick) private var tick = 10

    var body: some View {
        let theme = themes.theme
        let border = theme.colors.border.color
        VStack(spacing: 0) {
            if let error = themes.error {
                HStack {
                    Text("Theme: \(error)").lineLimit(2)
                    Spacer()
                    SettingsLink { Text("Open Settings") }
                }
                .foregroundStyle(theme.colors.text.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.colors.sell.color.opacity(0.25))
            }
            if theme.show.header {
                header(theme)
                border.frame(height: 1)
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if showIndicator {
                        IndicatorView(model: store.indicator, timeframe: timeframe, theme: theme)
                    }
                    if showIndicator && showDom {
                        border.frame(width: 1)
                    }
                    if showDom {
                        // in a narrow window the dom gives the chart at least 60% of the width
                        DomView(model: store.dom, tick: tick, theme: theme)
                            .frame(width: showIndicator ? min(theme.layout.domWidth, geometry.size.width * 0.4) : nil)
                    }
                    if !showIndicator && !showDom {
                        Text("Both views are off. Turn on Indicator or DOM (View menu, ⌘1 / ⌘2).")
                            .foregroundStyle(theme.colors.muted.color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            if theme.show.marketsBar {
                border.frame(height: 1)
                MarketsBar(store: store, theme: theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.colors.panel.color)
            }
        }
        .background(theme.colors.background.color)
        .toolbarBackground(theme.colors.panel.color, for: .windowToolbar)
        .preferredColorScheme(theme.appearance == .light ? .light : .dark)
        .tint(theme.colors.accent.color)
        // a new coin or timeframe loads its history, after the product lists are read
        .task(id: "\(store.markets)|\(timeframe)") {
            guard !store.markets.isEmpty else { return }
            await store.loadHistory(timeframe: timeframe)
        }
        .sheet(isPresented: Binding(get: { store.choosingCoin }, set: { store.choosingCoin = $0 })) {
            CoinPicker(store: store, theme: theme)
        }
    }

    // the widest layout that fits wins, so labels drop out one by one instead of wrapping letter by letter
    private func header(_ theme: Theme) -> some View {
        ViewThatFits(in: .horizontal) {
            headerRow(theme, subtitle: theme.show.headerSubtitle, labels: true)
            headerRow(theme, subtitle: false, labels: true)
            headerRow(theme, subtitle: false, labels: false)
        }
        .foregroundStyle(theme.colors.text.color)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.panel.color)
    }

    private func headerRow(_ theme: Theme, subtitle: Bool, labels: Bool) -> some View {
        HStack(spacing: labels ? 18 : 12) {
            if theme.show.headerPrice {
                Text(store.price.map(price) ?? "—")
                    .font(theme.mono(3, weight: .semibold))
                    .foregroundStyle(theme.colors.text.color)
                    .fixedSize()
                    .frame(minWidth: 90, alignment: .leading)
            }
            Button {
                store.choosingCoin = true
            } label: {
                HStack(spacing: 4) {
                    Text(store.coin).font(theme.mono(1, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.colors.text.color)
            .help("Choose a coin (⌘K)")
            .fixedSize()
            if subtitle {
                Text(store.catalogs == nil ? "loading markets…" : "\(store.markets.count) markets")
                    .foregroundStyle(theme.colors.muted.color)
                    .fixedSize()
            }
            Spacer(minLength: 12)
            Toggle("Indicator", isOn: $showIndicator).toggleStyle(.switch).fixedSize()
            Picker("Timeframe", selection: $timeframe) {
                ForEach(timeframes, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!showIndicator)
            theme.colors.border.color.frame(width: 1, height: 18)
            Toggle("DOM", isOn: $showDom).toggleStyle(.switch).fixedSize()
            // an empty title drops the label in the compact layouts
            Picker(labels ? "Row size" : "", selection: $tick) {
                ForEach(ticks, id: \.self) { Text(rowSize($0, unit: store.dom.unit)).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!showDom)
            if labels {
                Button("Reset DOM") { store.dom.reset() }.disabled(!showDom)
            } else {
                Button("Reset DOM", systemImage: "arrow.counterclockwise") { store.dom.reset() }
                    .labelStyle(.iconOnly)
                    .help("Reset DOM")
                    .disabled(!showDom)
            }
        }
    }
}

// connection state and trade count per market, to compare against aggr
struct MarketsBar: View {
    let store: MarketStore
    let theme: Theme

    var body: some View {
        FlowLayout {
            ForEach(store.markets, id: \.self) { market in
                let status = store.statuses[market]
                let count = store.tradeCounts[market]
                HStack(spacing: 5) {
                    Circle().fill(color(status, live: count != nil)).frame(width: 7, height: 7)
                    Text(market).foregroundStyle(theme.colors.muted.color)
                    Text("\(count ?? 0)").foregroundStyle(theme.colors.text.color)
                }
                .help(describe(status))
            }
            // an exchange whose product list failed has no markets to show, so it gets its own chip
            if let catalogs = store.catalogs {
                ForEach(catalogs.failures, id: \.exchange) { failure in
                    HStack(spacing: 5) {
                        Circle().fill(theme.colors.statusDown.color).frame(width: 7, height: 7)
                        Text("\(failure.exchange) products failed").foregroundStyle(theme.colors.muted.color)
                    }
                    .help(failure.reason)
                }
            }
        }
        .font(theme.mono(-1))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // nil is a socket that hasn't reported yet
    private func color(_ status: MarketStatus?, live: Bool) -> Color {
        let colors = theme.colors
        return switch status {
        case .open: (live ? colors.statusLive : colors.statusPending).color
        case nil, .connecting: colors.statusPending.color
        case .down: colors.statusDown.color
        }
    }

    private func describe(_ status: MarketStatus?) -> String {
        switch status {
        case nil: "starting"
        case .connecting: "connecting"
        case .open: "open"
        case .down(let reason): "down: \(reason)"
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
