import CounterpartyKit
import SwiftUI

// price ladder built from the aggregated trade flow: volume bought and sold at every level.
// aggr only streams trades (no order books), so this is the executed side of the dom.

private struct Level {
    var buy = 0.0
    var sell = 0.0
    var liqBuy = 0.0
    var liqSell = 0.0
    // last print here, for the flash
    var at = Date.distantPast
    var side = Side.buy
}

@MainActor @Observable
final class DomModel {
    // the smallest level, a ten-thousandth of the coin's price magnitude: $1 for btc, $0.01 for sol.
    // rows group levels by the selected tick, a multiple of this
    private(set) var unit: Double?
    @ObservationIgnored fileprivate var levels: [Int: Level] = [:]
    @ObservationIgnored fileprivate var lastPrices: [String: Double] = [:]

    func add(_ trades: [Trade]) {
        let now = Date()
        for trade in trades {
            let unit = unit ?? pow(10, floor(log10(trade.price)) - 4)
            self.unit = unit
            let key = Int((trade.price / unit).rounded(.down))
            if trade.liquidation {
                if trade.side == .buy { levels[key, default: Level()].liqBuy += trade.quote } else { levels[key, default: Level()].liqSell += trade.quote }
                continue
            }
            var level = levels[key, default: Level()]
            if trade.side == .buy { level.buy += trade.quote } else { level.sell += trade.quote }
            level.at = now
            level.side = trade.side
            levels[key] = level
            lastPrices[trade.market] = trade.price
        }
    }

    func reset() {
        levels = [:]
    }

    // another coin, its prices start over
    func clear() {
        levels = [:]
        lastPrices = [:]
        unit = nil
    }
}

private enum Column {
    case liquidations, sell, price, buy, delta

    var title: String {
        switch self {
        case .liquidations: "Liq"
        case .sell: "Sell"
        case .price: "Price"
        case .buy: "Buy"
        case .delta: "Delta"
        }
    }

    // share of the width left after the price column, which is sized to its labels instead
    var weight: Double {
        switch self {
        case .liquidations: 1
        case .sell, .buy: 2
        case .price: 0
        case .delta: 1.2
        }
    }

    var alignment: Alignment {
        switch self {
        case .liquidations: .leading
        case .sell: .trailing
        case .price: .center
        case .buy: .leading
        case .delta: .trailing
        }
    }
}

struct DomView: View {
    let model: DomModel
    let tick: Int
    let theme: Theme

    // liq and delta columns can be hidden by the theme
    private var columns: [Column] {
        [theme.show.domLiquidations ? .liquidations : nil, .sell, .price, .buy, theme.show.domDelta ? .delta : nil].compactMap { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if theme.show.domHeader {
                GeometryReader { geometry in
                    row(geometry.size.width) { column in
                        Text(column.title).foregroundStyle(theme.colors.muted.color)
                    }
                }
                .frame(height: theme.layout.domRowHeight)
                theme.colors.border.color.frame(height: 1)
            }
            GeometryReader { geometry in
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    ladder(size: geometry.size, now: context.date)
                }
            }
        }
        .font(theme.mono())
    }

    @ViewBuilder
    private func ladder(size: CGSize, now: Date) -> some View {
        if model.lastPrices.isEmpty {
            Text("waiting for trades…").foregroundStyle(theme.colors.muted.color).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let unit = model.unit {
            // centered on the average last price of all markets, like aggr's averaged candles
            let average = model.lastPrices.values.reduce(0, +) / Double(model.lastPrices.count)
            let center = Int(average / unit) / tick * tick
            let digits = max(0, -Int(log10(unit).rounded()))
            // 2 * half + 1 rows have to fit the panel
            let half = max(2, (Int(size.height / theme.layout.domRowHeight) - 1) / 2)
            let rows = (-half...half).reversed().map { offset in
                let price = center + offset * tick
                var total = Level()
                for key in price..<(price + tick) {
                    guard let level = model.levels[key] else { continue }
                    total.buy += level.buy
                    total.sell += level.sell
                    total.liqBuy += level.liqBuy
                    total.liqSell += level.liqSell
                    if level.at > total.at {
                        total.at = level.at
                        total.side = level.side
                    }
                }
                return (price, total)
            }
            let largest = max(1, rows.map { max($0.1.buy, $0.1.sell) }.max() ?? 1)
            let colors = theme.colors

            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { price, level in
                    let delta = level.buy - level.sell
                    let flash = now.timeIntervalSince(level.at) < 0.6
                    // levels with under a dollar stay blank so dust trades don't print "0"
                    let cell = { (value: Double) in abs(value) >= 1 ? usd(value) : "" }
                    row(size.width, sell: level.sell / largest, buy: level.buy / largest) { column in
                        switch column {
                        case .liquidations:
                            Text(cell(level.liqBuy + level.liqSell)).foregroundStyle(colors.domLiquidation.color)
                        case .sell:
                            Text(cell(level.sell)).foregroundStyle(colors.text.color)
                        case .price:
                            Text((Double(price) * unit).formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US"))))
                                .foregroundStyle((flash ? (level.side == .buy ? colors.domFlashBuy : colors.domFlashSell) : colors.text).color)
                        case .buy:
                            Text(cell(level.buy)).foregroundStyle(colors.text.color)
                        case .delta:
                            Text((delta >= 1 ? "+" : "") + cell(delta)).foregroundStyle((delta >= 0 ? colors.buy : colors.sell).color)
                        }
                    }
                    .background(price == center ? colors.domCurrentRow.color : .clear)
                    .fontWeight(price == center ? .semibold : .regular)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .clipped()
        }
    }

    // one ladder row: the sell bar grows right to left toward the price, the buy bar left to right
    private func row(_ width: Double, sell: Double = 0, buy: Double = 0, cell: @escaping (Column) -> Text) -> some View {
        // labels are "80,175" for btc and "0.0000000025" for pepe, as many decimals as the coin's unit
        let decimals = model.unit.map { max(0, -Int(log10($0).rounded())) }
        let characters = max(7, (decimals ?? 0) + 2)
        let priceWidth = Double(characters) * theme.font.size * 0.62 + 12
        let unit = (width - 16 - priceWidth) / columns.map(\.weight).reduce(0, +)
        return HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                let columnWidth = column == .price ? priceWidth : unit * column.weight
                let bar = column == .sell ? sell : column == .buy ? buy : 0
                cell(column)
                    .padding(.horizontal, column == .sell || column == .buy ? 4 : 0)
                    .frame(width: columnWidth, alignment: column.alignment)
                    .background(alignment: column.alignment) {
                        if theme.show.domBars && bar > 0 {
                            (column == .sell ? theme.colors.domSellBar : theme.colors.domBuyBar).color
                                .frame(width: columnWidth * bar)
                                .padding(.vertical, 2)
                        }
                    }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: theme.layout.domRowHeight)
    }
}
