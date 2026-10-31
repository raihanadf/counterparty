import AppKit
import CounterpartyKit
import SwiftUI

@main
struct CounterpartyApp: App {
    @State private var workspace = Workspace()
    @State private var themes = ThemeStore()
    @State private var help = HelpMode()
    @State private var updater = Updater()

    init() {
        // a bare executable (swift run) starts as a background process without this
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Counterparty", id: "main") {
            ContentView(workspace: workspace, themes: themes, updater: updater)
                .environment(help)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    NSApplication.shared.activate()
                    updater.start()
                    await workspace.start()
                }
        }
        .defaultSize(width: 1400, height: 860)
        .commands { AppCommands(workspace: workspace, themes: themes, help: help) }

        Settings {
            SettingsView(themes: themes, updater: updater)
        }
    }
}

// toggles and selections survive a relaunch
private enum Keys {
    static let showIndicator = "showIndicator"
    static let showDom = "showDom"
    static let timeframe = "timeframe"
}

private let timeframes = [(5, "5s"), (15, "15s"), (60, "1m"), (300, "5m"), (900, "15m")]

// menus mirror the header, so everything stays reachable when a theme hides it
struct AppCommands: Commands {
    let workspace: Workspace
    let themes: ThemeStore
    let help: HelpMode

    @AppStorage(Keys.showIndicator) private var showIndicator = true
    @AppStorage(Keys.showDom) private var showDom = true
    @AppStorage(Keys.timeframe) private var timeframe = 60

    var body: some Commands {
        // ⌘P is search everywhere in the app, there's nothing to print
        CommandGroup(replacing: .printItem) {
            Button("Search Coins…") { workspace.search = .replace }.keyboardShortcut("p")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab…") { workspace.search = .newTab }.keyboardShortcut("t")
            Button("Close Tab") {
                if let selected = workspace.selected { workspace.close(selected) }
            }
            .keyboardShortcut("w")
            .disabled(workspace.tabs.count < 2)
        }
        CommandMenu("Tabs") {
            Button("Next Tab") { workspace.selectNeighbor(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { workspace.selectNeighbor(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(Array(workspace.tabs.prefix(9).enumerated()), id: \.element.id) { index, session in
                Button(session.coin) { workspace.select(number: index + 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index == 8 ? 9 : index + 1)")))
            }
        }
        CommandGroup(before: .toolbar) {
            Toggle("Indicator", isOn: $showIndicator).keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("DOM", isOn: $showDom).keyboardShortcut("d", modifiers: [.command, .option])
            Picker("Timeframe", selection: $timeframe) {
                ForEach(timeframes, id: \.0) { Text($0.1).tag($0.0) }
            }
            Toggle("Explain Numbers", isOn: Binding(get: { help.on }, set: { help.on = $0 })).keyboardShortcut("/")
            Picker("Theme", selection: Binding(get: { themes.choice }, set: { themes.choose($0) })) {
                ForEach(themes.choices, id: \.self) { Text(themes.title(of: $0)).tag($0) }
            }
            Divider()
        }
    }
}

struct ContentView: View {
    let workspace: Workspace
    let themes: ThemeStore
    let updater: Updater

    @AppStorage(Keys.showIndicator) private var showIndicator = true
    @AppStorage(Keys.showDom) private var showDom = true
    @AppStorage(Keys.timeframe) private var timeframe = 60
    @Environment(HelpMode.self) private var help
    // the launch intro plays once, over everything, until the markets are in
    @State private var introDone = false

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
            if let session = workspace.selected {
                if theme.show.tabs {
                    TabStrip(workspace: workspace, theme: theme)
                    border.frame(height: 1)
                }
                if theme.show.header {
                    HeaderBar(workspace: workspace, session: session, theme: theme)
                    border.frame(height: 1)
                }
                panes(session, theme)
                    // a new tab or timeframe starts the chart fresh: scrolled to now, auto-scaled
                    .id("\(session.id)|\(timeframe)")
                    .task(id: "\(session.id)|\(timeframe)") { await session.loadHistory(timeframe: timeframe) }
                if theme.show.marketsBar {
                    border.frame(height: 1)
                    MarketsBar(session: session, failures: workspace.catalogs?.failures, theme: theme)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.colors.panel.color)
                }
            } else {
                ProgressView("Reading every exchange's markets…")
                    .foregroundStyle(theme.colors.muted.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.colors.background.color)
        .coordinateSpace(.named(HelpMode.space))
        .overlay { HelpCard(help: help, theme: theme) }
        // esc leaves the (?) mode
        .background {
            if help.on {
                Button("") { help.on = false }.keyboardShortcut(.cancelAction).hidden()
            }
        }
        .toolbarBackground(theme.colors.panel.color, for: .windowToolbar)
        .preferredColorScheme(theme.appearance == .light ? .light : .dark)
        .tint(theme.colors.accent.color)
        .overlay {
            if !introDone {
                IntroView(ready: workspace.selected != nil, theme: theme) { introDone = true }
            }
        }
        // the other tabs' history loads in the background, in the same timeframe
        .task(id: "\(timeframe)|\(workspace.tabs.map(\.id))") { await workspace.prefetch(timeframe: timeframe) }
        .sheet(item: Binding(get: { workspace.search }, set: { workspace.search = $0 })) { mode in
            CoinPicker(workspace: workspace, mode: mode, theme: theme)
        }
        // a new version is out: what's new, install now or later. it waits for the intro to finish
        .sheet(item: Binding(get: { introDone ? updater.prompt : nil }, set: { if $0 == nil { updater.later() } })) { release in
            UpdatePrompt(updater: updater, release: release, theme: theme)
        }
    }

    private func panes(_ session: CoinSession, _ theme: Theme) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if showIndicator {
                    IndicatorView(model: session.indicator, timeframe: timeframe, theme: theme)
                }
                if showIndicator && showDom {
                    theme.colors.border.color.frame(width: 1)
                }
                if showDom {
                    // in a narrow window the dom gives the chart at least 60% of the width
                    DomView(coin: session.coin, book: session.book, tapes: session.tapes, bookMarkets: session.markets.filter { hasBook($0) }, theme: theme)
                        .frame(width: showIndicator ? min(theme.layout.domWidth, geometry.size.width * 0.4) : nil)
                }
                if !showIndicator && !showDom {
                    Text("Both views are off. Turn on Indicator or DOM (View menu, ⌥⌘I / ⌥⌘D).")
                        .foregroundStyle(theme.colors.muted.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// the header is its own view, so its live price only redraws the header and not the chart and ladder under it
struct HeaderBar: View {
    let workspace: Workspace
    let session: CoinSession
    let theme: Theme

    @AppStorage(Keys.showIndicator) private var showIndicator = true
    @AppStorage(Keys.showDom) private var showDom = true
    @AppStorage(Keys.timeframe) private var timeframe = 60

    // the widest layout that fits wins, so labels drop out one by one instead of wrapping letter by letter
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(subtitle: theme.show.headerSubtitle, labels: true)
            row(subtitle: false, labels: true)
            row(subtitle: false, labels: false)
        }
        .foregroundStyle(theme.colors.text.color)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.panel.color)
    }

    private func row(subtitle: Bool, labels: Bool) -> some View {
        HStack(spacing: labels ? 20 : 12) {
            if theme.show.headerPrice {
                LivePrice(session: session)
                    .font(theme.mono(6, weight: .medium))
                    .tracking(-0.4)
                    .monospacedDigit()
                    .foregroundStyle(theme.colors.text.color)
                    .fixedSize()
                    .explain(Hint(
                        "Last traded price: the newest trade from any of \(session.coin)'s perps, refreshed twice a second. It mixes exchanges, so it can sit a few dollars off any single exchange's own price.",
                        example: "Fine: this reads 77,140 while Binance shows 77,138, that's two venues a tick apart. Not fine: it sits far from the chart's last close for long, one venue is lagging; check the bar at the bottom for a market that's down."
                    ))
                    .frame(minWidth: 110, alignment: .leading)
            }
            Button {
                workspace.search = .replace
            } label: {
                HStack(spacing: 6) {
                    Text(session.coin).font(theme.mono(1, weight: .semibold)).tracking(0.6)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                        .foregroundStyle(theme.colors.muted.color)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.colors.border.color))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.text.color)
            .help("Search coins (⌘P)")
            .fixedSize()
            .explain(Hint(
                "The coin on screen. Click it, or press ⌘P, to search every coin that has a perp.",
                example: "⌘P then type SOL and ⏎ swaps this tab to SOL; ⌘⏎ opens SOL in a new tab and keeps this one streaming."
            ))
            if subtitle {
                CapsLabel("\(session.markets.count) perps", theme: theme)
                    .fixedSize()
                    .explain(Hint(
                        "\(session.markets.count) perpetual futures feed this coin: every USDT, USDC and coin-margined perp of it on Binance Futures, Bitfinex, Bybit, Deribit and OKX. Each one is listed in the bar at the bottom.",
                        example: "More perps means a truer picture: BTC's 10 markets show the whole market's flow. A small coin with 1 perp shows one venue only, so its volume and liquidations are a slice, not the market."
                    ))
            }
            Spacer(minLength: 12)
            Toggle("Indicator", isOn: $showIndicator).toggleStyle(LampToggleStyle(theme: theme)).fixedSize()
                .explain(Hint("Shows or hides the chart (⌥⌘I).", example: "Turn it off to give the whole window to the order book while you watch a level get tested."))
            RuleSegments(items: timeframes.map(\.0), selection: $timeframe, theme: theme) { seconds, _ in
                Text(timeframes.first { $0.0 == seconds }!.1).font(theme.mono(-1))
            }
            .fixedSize()
            .disabled(!showIndicator)
            .explain(Hint(
                "How much time one candle covers. History comes from aggr's server, so every timeframe has the same data aggr.trade shows.",
                example: "5m or 15m to see the trend and the levels that matter. 5s or 15s to watch how price acts right at one of those levels. Trading off 5s alone means reacting to noise."
            ))
            theme.colors.border.color.frame(width: 1, height: 14)
            Toggle("DOM", isOn: $showDom).toggleStyle(LampToggleStyle(theme: theme)).fixedSize()
                .explain(Hint("Shows or hides the order book ladder (⌥⌘D).", example: "Turn it off when you only want the chart; the book keeps streaming in the background so it's ready when it comes back."))
        }
    }
}

// just the number, the only part of the header and the tabs that changes every half second
struct LivePrice: View {
    let session: CoinSession

    var body: some View {
        if let value = session.price, let decimals = session.indicator.decimals {
            Text(price(value, decimals: decimals))
        } else {
            Text("—")
        }
    }
}

// one tab per open coin, with its live price, like browser tabs
struct TabStrip: View {
    let workspace: Workspace
    let theme: Theme
    @Environment(HelpMode.self) private var help

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, session in
                        TabItem(workspace: workspace, session: session, number: index + 1, theme: theme)
                    }
                }
                .padding(.horizontal, 8)
            }
            Button {
                help.on.toggle()
            } label: {
                Image(systemName: help.on ? "questionmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: 13, weight: .light))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle((help.on ? theme.colors.accent : theme.colors.muted).color)
            .help(help.on ? "Stop explaining (esc)" : "Explain what everything means: hover anything (⌘/)")
            theme.colors.border.color.frame(width: 1, height: 14)
            Button {
                workspace.search = .newTab
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .light))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.muted.color)
            .help("New tab (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(theme.colors.background.color)
    }
}

// each tab its own view, so one coin's price tick redraws that tab only
struct TabItem: View {
    let workspace: Workspace
    let session: CoinSession
    let number: Int
    let theme: Theme

    var body: some View {
        let selected = workspace.selected === session
        HStack(spacing: 8) {
            Text(session.coin).font(theme.mono(-1, weight: selected ? .semibold : .medium)).tracking(0.6)
            // green or red against the last closed bar, so a background tab still says which way it's going
            LivePrice(session: session)
                .font(theme.mono(-1))
                .foregroundStyle(session.rising.map { ($0 ? theme.colors.buy : theme.colors.sell).color } ?? theme.colors.muted.color)
            if workspace.tabs.count > 1 {
                Button {
                    workspace.close(session)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .semibold))
                        .frame(width: 12, height: 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.muted.color)
                .help("Close tab (⌘W)")
            }
        }
        .foregroundStyle((selected ? theme.colors.text : theme.colors.muted).color)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        // the open tab is lit: the header's panel under a brass rule, the way a drawer pulls out
        .background(selected ? theme.colors.panel.color : .clear)
        .overlay(alignment: .top) {
            if selected { theme.colors.accent.color.frame(height: 1.5) }
        }
        .overlay(alignment: .trailing) {
            if !selected { theme.colors.border.color.frame(width: 1, height: 12) }
        }
        .contentShape(.rect)
        .onTapGesture { workspace.select(session) }
        .help(number <= 9 ? "⌘\(number)" : "")
        .draggable(session.coin)
        .dropDestination(for: String.self) { coins, _ in
            guard let coin = coins.first, let moved = workspace.tabs.first(where: { $0.coin == coin }) else { return false }
            workspace.move(moved, before: session)
            return true
        }
        .explain(Hint(
            "\(session.coin) tab. The number is the last traded price, in the buy colour when it's above the close of the previous bar in the chart's timeframe and the sell colour when below. Every tab keeps streaming in the background. \(number <= 9 ? "⌘\(number) jumps here, d" : "D")rag to reorder.",
            example: "Keep the coins you trade open as tabs: with BTC on screen, an ETH tab flipping to the sell colour tells you ETH is weakening before you look at it."
        ))
    }
}

// connection state and trade count per market, to compare against aggr
struct MarketsBar: View {
    let session: CoinSession
    // exchanges whose product list failed, nil while they're still loading
    let failures: [(exchange: String, reason: String)]?
    let theme: Theme

    var body: some View {
        FlowLayout {
            ForEach(session.markets, id: \.self) { market in
                let status = session.statuses[market]
                let count = session.tradeCounts[market]
                HStack(spacing: 6) {
                    Circle().fill(color(status, live: count != nil)).frame(width: 5, height: 5)
                    Text(market).foregroundStyle(theme.colors.muted.color)
                    Text("\(count ?? 0)").foregroundStyle(theme.colors.text.color).monospacedDigit()
                }
                .help(describe(status))
                .explain(Hint(
                    "\(market): one perp feeding \(session.coin), exchange then its own symbol. \(count ?? 0) trades came in since this tab opened. The dot is the connection, now \(describe(status)). Its colour is live when trades are arriving, pending while connecting or before the first trade, and down when the socket dropped and is retrying.",
                    example: "Normal: big venues count hundreds while Deribit or Bitfinex count a few dozen, they're smaller. A problem: a big venue stuck at 0 or a down dot for minutes. Its flow is missing from the chart, so volume and delta read low."
                ))
            }
            // an exchange whose product list failed has no markets to show, so it gets its own chip
            if let failures {
                ForEach(failures, id: \.exchange) { failure in
                    HStack(spacing: 6) {
                        Circle().fill(theme.colors.statusDown.color).frame(width: 5, height: 5)
                        Text("\(failure.exchange) products failed").foregroundStyle(theme.colors.muted.color)
                    }
                    .help(failure.reason)
                    .explain(Hint(
                        "\(failure.exchange)'s market list couldn't be read, so its perps are missing from this coin: \(failure.reason)",
                        example: "Until it comes back, the chart and volume leave that exchange out. Reopening the app retries the list."
                    ))
                }
            }
        }
        .font(theme.mono(-2))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
    var spacing = 20.0
    var lineSpacing = 6.0

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

// a label on the chrome: caps, letter-spaced, in the theme's muted colour
struct CapsLabel: View {
    let text: String
    let theme: Theme
    var color: ThemeColor?

    init(_ text: String, theme: Theme, color: ThemeColor? = nil) {
        self.text = text
        self.theme = theme
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(theme.caps())
            .tracking(1.2)
            .foregroundStyle((color ?? theme.colors.muted).color)
    }
}

// a quiet switch: a small square lamp that lights in the accent, then the label in caps
struct LampToggleStyle: ToggleStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(on ? theme.colors.accent.color : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder((on ? theme.colors.accent : theme.colors.muted).color, lineWidth: 1))
                    .frame(width: 7, height: 7)
                configuration.label
                    .textCase(.uppercase)
                    .font(theme.caps())
                    .tracking(1.2)
                    .foregroundStyle((on ? theme.colors.text : theme.colors.muted).color)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// a row of choices where the chosen one sits on a brass rule: the header's timeframes and the search's tabs
struct RuleSegments<Value: Hashable, Label: View>: View {
    let items: [Value]
    @Binding var selection: Value
    let theme: Theme
    @ViewBuilder let label: (Value, Bool) -> Label

    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let chosen = item == selection
                Button {
                    selection = item
                } label: {
                    label(item, chosen)
                        .foregroundStyle((chosen && enabled ? theme.colors.text : theme.colors.muted).color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) {
                            if chosen {
                                (enabled ? theme.colors.accent : theme.colors.border).color.frame(height: 1.5).padding(.horizontal, 6)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
