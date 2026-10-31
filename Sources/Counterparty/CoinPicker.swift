import CounterpartyKit
import SwiftUI

// ⌘P search over every coin with a perp, tabbed like bybit's market list: all, the open tabs,
// then bybit's own groups (crypto, innovation, stocks, ...). type to filter, ↑↓ to move,
// return opens it here, ⌘return in a new tab, tab and shift-tab switch between the tabs
struct CoinPicker: View {
    let workspace: Workspace
    let mode: Workspace.SearchMode
    let theme: Theme

    private enum Filter: Hashable {
        case all, open
        case kind(CoinKind)
    }

    @State private var query = ""
    @State private var filter = Filter.all
    @State private var highlight = 0
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    private var filters: [Filter] {
        [.all, .open] + Set(workspace.coins.map(\.kind)).sorted().map { .kind($0) }
    }

    private func coins(in filter: Filter) -> [Coin] {
        switch filter {
        case .all:
            return workspace.coins
        case .open:
            // in tab order
            let open = workspace.tabs.map(\.coin)
            return open.compactMap { symbol in workspace.coins.first { $0.symbol == symbol } }
        case .kind(let kind):
            return workspace.coins.filter { $0.kind == kind }
        }
    }

    private func matches(in filter: Filter) -> [Coin] {
        let text = query.trimmingCharacters(in: .whitespaces).uppercased()
        let coins = coins(in: filter)
        guard !text.isEmpty else { return coins }
        // exact match, then prefix matches, then coins that only contain the text, each kept in their order
        let rank = { (coin: Coin) -> Int in coin.symbol == text ? 0 : coin.symbol.hasPrefix(text) ? 1 : 2 }
        let found = coins.filter { $0.symbol.contains(text) }
        return (0...2).flatMap { level in found.filter { rank($0) == level } }
    }

    var body: some View {
        let matches = matches(in: filter)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .light)).foregroundStyle(theme.colors.muted.color)
                TextField(mode == .newTab ? "Open a coin in a new tab" : "Search coins, e.g. ETH, SOL, PEPE", text: $query)
                    .textFieldStyle(.plain)
                    .font(theme.mono(4))
                    .focused($searching)
                    .onSubmit {
                        guard matches.indices.contains(highlight) else { return }
                        let newTab = NSEvent.modifierFlags.contains(.command)
                        pick(matches[highlight].symbol, newTab: newTab || mode == .newTab)
                    }
                    .onKeyPress(.downArrow) {
                        highlight = min(highlight + 1, matches.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlight = max(highlight - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            tabs
            theme.colors.border.color.frame(height: 1)

            if workspace.catalogs == nil {
                ProgressView("Reading every exchange's markets…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                Text(query.isEmpty ? "Nothing here" : "No \"\(query.uppercased())\" perp in \(title(filter))")
                    .foregroundStyle(theme.colors.muted.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(matches)
            }

            theme.colors.border.color.frame(height: 1)
            HStack(spacing: 16) {
                ForEach([("↑↓", "move"), ("⏎", "open"), ("⌘⏎", "new tab"), ("⇥", "next tab")], id: \.0) { key, action in
                    HStack(spacing: 6) {
                        Text(key).font(theme.mono(-2)).foregroundStyle(theme.colors.text.color)
                        CapsLabel(action, theme: theme)
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    CapsLabel("Cancel", theme: theme, color: theme.colors.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.colors.border.color))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 700, height: 560)
        .background(theme.colors.panel.color)
        .tint(theme.colors.accent.color)
        .onAppear { searching = true }
        .onChange(of: query) { highlight = 0 }
        .onChange(of: filter) { highlight = 0 }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // group names keep their own case (ETFs, not ETFS), only the chrome's labels are set in caps
            RuleSegments(items: filters, selection: $filter, theme: theme) { item, chosen in
                HStack(spacing: 6) {
                    Text(title(item)).font(theme.prose(-1, weight: chosen ? .semibold : .medium))
                    Text("\(matches(in: item).count)")
                        .font(theme.mono(-2))
                        .foregroundStyle((chosen ? theme.colors.accent : theme.colors.muted).color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func list(_ matches: [Coin]) -> some View {
        ScrollViewReader { scroller in
            List {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, coin in
                    row(coin, highlighted: index == highlight)
                        .id(coin.id)
                        .contentShape(.rect)
                        .onTapGesture {
                            pick(coin.symbol, newTab: mode == .newTab || NSEvent.modifierFlags.contains(.command))
                        }
                        .listRowBackground(highlightBackground(index == highlight))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: highlight) { _, index in
                if matches.indices.contains(index) { scroller.scrollTo(matches[index].id) }
            }
        }
    }

    // the highlighted row: a brass wash with a brass rule on its left edge
    @ViewBuilder
    private func highlightBackground(_ on: Bool) -> some View {
        if on {
            theme.colors.accent.color.opacity(0.1)
                .overlay(alignment: .leading) { theme.colors.accent.color.frame(width: 2) }
        } else {
            Color.clear
        }
    }

    private func row(_ coin: Coin, highlighted: Bool) -> some View {
        let open = workspace.tabs.contains { $0.coin == coin.symbol }
        return HStack(spacing: 10) {
            Text(coin.symbol).font(theme.mono(1, weight: open ? .bold : .medium)).tracking(0.4)
            if coin.kind != .crypto && filter != .kind(coin.kind) {
                Text(coin.kind.title).font(theme.prose(-3, weight: .medium)).foregroundStyle(theme.colors.muted.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.colors.border.color))
            }
            if open {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(theme.colors.accent.color).help("open in a tab")
            }
            Spacer()
            Text(summary(coin)).font(theme.mono(-2)).foregroundStyle(theme.colors.muted.color).lineLimit(1)
            Text("\(coin.markets.count)").font(theme.mono(-1)).foregroundStyle((highlighted ? theme.colors.accent : theme.colors.text).color).frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .foregroundStyle(theme.colors.text.color)
    }

    private func title(_ filter: Filter) -> String {
        switch filter {
        case .all: "All"
        case .open: "Open"
        case .kind(let kind): kind.title
        }
    }

    private func step(_ direction: Int) {
        let all = filters
        guard let index = all.firstIndex(of: filter) else { return }
        filter = all[(index + direction + all.count) % all.count]
    }

    // which exchanges carry it, e.g. "BINANCE_FUTURES · BYBIT · OKEX"
    private func summary(_ coin: Coin) -> String {
        var seen: [String] = []
        for market in coin.markets {
            let exchange = String(market.prefix { $0 != ":" })
            if !seen.contains(exchange) { seen.append(exchange) }
        }
        return seen.joined(separator: " · ")
    }

    private func pick(_ symbol: String, newTab: Bool) {
        workspace.open(symbol, mode: newTab ? .newTab : .replace)
        dismiss()
    }
}
