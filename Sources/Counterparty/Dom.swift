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

@MainActor
final class DomModel {
    // kept per whole dollar, rows group them by the selected tick
    fileprivate var levels: [Int: Level] = [:]
    fileprivate var lastPrices: [String: Double] = [:]

    func add(_ trades: [Trade]) {
        let now = Date()
        for trade in trades {
            let dollar = Int(trade.price.rounded(.down))
            if trade.liquidation {
                if trade.side == .buy { levels[dollar, default: Level()].liqBuy += trade.quote } else { levels[dollar, default: Level()].liqSell += trade.quote }
                continue
            }
            var level = levels[dollar, default: Level()]
            if trade.side == .buy { level.buy += trade.quote } else { level.sell += trade.quote }
            level.at = now
            level.side = trade.side
            levels[dollar] = level
            lastPrices[trade.market] = trade.price
        }
    }

    func reset() {
        levels = [:]
    }
}

private let rowHeight = 20.0
// liq, sell, price, buy, delta
private let columns = [1.0, 2.0, 1.4, 2.0, 1.2]

struct DomView: View {
    let model: DomModel
    let tick: Int

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                row(geometry.size.width, ["Liq", "Sell", "Price", "Buy", "Delta"].map { Text($0).foregroundStyle(.secondary) })
            }
            .frame(height: rowHeight)
            Divider()
            GeometryReader { geometry in
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    ladder(size: geometry.size, now: context.date)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    @ViewBuilder
    private func ladder(size: CGSize, now: Date) -> some View {
        if model.lastPrices.isEmpty {
            Text("waiting for trades…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // centered on the average last price of all markets, like aggr's averaged candles
            let average = model.lastPrices.values.reduce(0, +) / Double(model.lastPrices.count)
            let center = Int(average) / tick * tick
            // 2 * half + 1 rows have to fit the panel
            let half = max(2, (Int(size.height / rowHeight) - 1) / 2)
            let rows = (-half...half).reversed().map { offset in
                let price = center + offset * tick
                var total = Level()
                for dollar in price..<(price + tick) {
                    guard let level = model.levels[dollar] else { continue }
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

            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { price, level in
                    let delta = level.buy - level.sell
                    let flash = now.timeIntervalSince(level.at) < 0.6
                    // levels with under a dollar stay blank so dust trades don't print "0"
                    let cell = { (value: Double) in abs(value) >= 1 ? usd(value) : "" }
                    row(size.width, [
                        Text(cell(level.liqBuy + level.liqSell)).foregroundStyle(Color(red: 1, green: 183 / 255, blue: 77 / 255)),
                        Text(cell(level.sell)),
                        Text(price.formatted(.number.locale(Locale(identifier: "en_US"))))
                            .foregroundStyle(flash ? (level.side == .buy ? Color.green : Color.red) : Color.primary),
                        Text(cell(level.buy)),
                        Text((delta >= 1 ? "+" : "") + cell(delta)).foregroundStyle(delta >= 0 ? Color.green : Color.red)
                    ], sell: level.sell / largest, buy: level.buy / largest)
                    .background(price == center ? Color.white.opacity(0.08) : .clear)
                    .fontWeight(price == center ? .semibold : .regular)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .clipped()
        }
    }

    // one ladder row: the sell bar grows right to left toward the price, the buy bar left to right
    private func row(_ width: Double, _ cells: [Text], sell: Double = 0, buy: Double = 0) -> some View {
        let unit = (width - 16) / columns.reduce(0, +)
        return HStack(spacing: 0) {
            cells[0].frame(width: unit * columns[0], alignment: .leading)
            cells[1].padding(.horizontal, 4).frame(width: unit * columns[1], alignment: .trailing)
                .background(alignment: .trailing) { Color.red.opacity(0.35).frame(width: unit * columns[1] * sell).padding(.vertical, 2) }
            cells[2].frame(width: unit * columns[2], alignment: .center)
            cells[3].padding(.horizontal, 4).frame(width: unit * columns[3], alignment: .leading)
                .background(alignment: .leading) { Color.green.opacity(0.35).frame(width: unit * columns[3] * buy).padding(.vertical, 2) }
            cells[4].frame(width: unit * columns[4], alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
    }
}
