import CounterpartyKit
import SwiftUI

// every coin listed by at least one exchange, the most widely traded first. typing filters, return picks the top match
struct CoinPicker: View {
    let store: MarketStore
    let theme: Theme

    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    private var matches: [Coin] {
        let text = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !text.isEmpty else { return store.coins }
        // exact match, then prefix matches, then coins that only contain the text, each kept in market-count order
        let rank = { (coin: Coin) -> Int in coin.symbol == text ? 0 : coin.symbol.hasPrefix(text) ? 1 : 2 }
        let found = store.coins.filter { $0.symbol.contains(text) }
        return (0...2).flatMap { level in found.filter { rank($0) == level } }
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            TextField("Search coins, e.g. ETH, SOL, PEPE", text: $query)
                .textFieldStyle(.plain)
                .font(theme.mono(2))
                .padding(12)
                .focused($searching)
                .onSubmit {
                    if let coin = matches.first { pick(coin.symbol) }
                }
            theme.colors.border.color.frame(height: 1)

            if store.catalogs == nil {
                ProgressView("Reading every exchange's markets…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                Text("No exchange has a \"\(query.uppercased())\" perp")
                    .foregroundStyle(theme.colors.muted.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches, selection: $selection) { coin in
                    HStack {
                        Text(coin.symbol).font(theme.mono(1, weight: coin.symbol == store.coin ? .bold : .regular))
                        Spacer()
                        Text(summary(coin)).foregroundStyle(theme.colors.muted.color).lineLimit(1)
                        Text("\(coin.markets.count)").font(theme.mono()).frame(width: 28, alignment: .trailing)
                    }
                    .tag(coin.symbol)
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, symbol in
                    if let symbol { pick(symbol) }
                }
            }

            theme.colors.border.color.frame(height: 1)
            HStack {
                Text("\(matches.count) coins · every perp the exchanges list for the coin")
                    .foregroundStyle(theme.colors.muted.color)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .font(.caption)
            .padding(10)
        }
        .frame(width: 560, height: 520)
        .onAppear { searching = true }
    }

    // which exchanges carry it, e.g. "BYBIT · BINANCE · OKEX"
    private func summary(_ coin: Coin) -> String {
        var seen: [String] = []
        for market in coin.markets {
            let exchange = String(market.prefix { $0 != ":" })
            if !seen.contains(exchange) { seen.append(exchange) }
        }
        return seen.joined(separator: " · ")
    }

    private func pick(_ symbol: String) {
        if symbol != store.coin { store.select(symbol) }
        dismiss()
    }
}
