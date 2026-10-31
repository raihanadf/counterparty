import CounterpartyKit
import SwiftUI

// a book or a tape value: 12.5, 1.2K, 3.4M, and two significant digits below 1, so an okx
// order of 0.0001 btc reads 0.0001 instead of 0.000
private func quantity(_ value: Double) -> String {
    let size = abs(value)
    if size >= 1e6 { return String(format: "%.1fM", size / 1e6) }
    if size >= 1e3 { return String(format: "%.1fK", size / 1e3) }
    if size >= 1 { return String(format: "%.2f", size) }
    if size == 0 { return "0" }
    return String(format: "%.\(max(3, 1 - Int(floor(log10(size)))))f", size)
}

// the order book of one venue, the ladder you read the market off: sizes resting above and below
// the price come and go without a trade happening
struct DomView: View {
    let coin: String
    let book: BookModel
    // every market's newest trades, the tape beside the ladder is the book's own market
    let tapes: [String: [Trade]]
    // the coin's markets that have a real order book
    let bookMarkets: [String]
    let theme: Theme

    @AppStorage("bookVenue") private var venue = ""

    private var market: String? {
        bookMarkets.first { $0.hasPrefix(venue + ":") } ?? bookMarkets.first
    }

    // one entry per exchange that has a book for this coin
    private var venues: [String] {
        var seen: [String] = []
        for market in bookMarkets {
            let exchange = String(market.prefix { $0 != ":" })
            if !seen.contains(exchange) { seen.append(exchange) }
        }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            if let market {
                controls(market)
                ladder
            } else {
                Text("No USDT or USDC perp for this coin, so no order book. Inverse books count USD contracts instead of the coin.")
                    .foregroundStyle(theme.colors.muted.color)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(theme.mono())
        .task(id: market) { book.watch(market) }
        .onDisappear { book.stop() }
    }

    private func controls(_ market: String) -> some View {
        HStack(spacing: 8) {
            CapsLabel("Book", theme: theme)
            Menu {
                ForEach(venues, id: \.self) { exchange in
                    Button(shortName(exchange)) { venue = exchange }
                }
            } label: {
                Text(venueLabel(market)).font(theme.mono(-1, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .tint(theme.colors.text.color)
            .fixedSize()
            .disabled(venues.count < 2)
            .help("Which exchange's book to watch")
            .explain(Hint(
                "The exchange whose order book is shown, and its symbol. Every exchange has its own book; they're never merged, because orders on one can't fill against another. \(venues.count > 1 ? "Click to pick another: \(venues.map(shortName).joined(separator: ", "))." : "No other exchange lists this coin's USDT or USDC perp.")",
                example: "Read sizes against the venue. On Binance, where most of the volume trades, a level that matches a minute of trading is ordinary. On a thin venue like Deribit the same size can be a wall that holds for hours. Good habit: watch the busiest venue's book, because that's where price is decided."
            ))
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(theme.colors.panel.color)
        .overlay(alignment: .bottom) { theme.colors.border.color.frame(height: 1) }
    }

    private func shortName(_ exchange: String) -> String {
        switch exchange {
        case "BINANCE_FUTURES": "Binance"
        case "BYBIT": "Bybit"
        case "OKEX": "OKX"
        case "DERIBIT": "Deribit"
        default: exchange
        }
    }

    private func venueLabel(_ market: String) -> String {
        let parts = market.split(separator: ":", maxSplits: 1)
        return "\(shortName(String(parts[0]))) \(parts[1])"
    }

    @ViewBuilder
    private var ladder: some View {
        if let error = book.error {
            VStack(spacing: 6) {
                Text("book failed").foregroundStyle(theme.colors.text.color)
                Text(error).foregroundStyle(theme.colors.muted.color).multilineTextAlignment(.center)
            }
            .font(theme.mono(-1))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot = book.book {
            BookLadderView(book: snapshot, coin: coin, tape: (tapes[snapshot.market] ?? []).reversed(), theme: theme)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// the resting orders around the price: bids below it on the left, asks above it on the right,
// and the tape of that same market beside them
struct BookLadderView: View {
    let book: Book
    let coin: String
    // newest first, the same market as the book
    let tape: [Trade]
    let theme: Theme

    var body: some View {
        GeometryReader { geometry in
            let tapeWidth = geometry.size.width > 380 ? min(148, geometry.size.width * 0.3) : 0
            HStack(spacing: 0) {
                Canvas { context, size in draw(&context, size) }
                    .explain { point, size in explanation(at: point, size) }
                if tapeWidth > 0 {
                    theme.colors.border.color.frame(width: 1)
                    tapeView(rows: Int(geometry.size.height / theme.layout.domRowHeight))
                        .frame(width: tapeWidth)
                        .explain { point, size in tapeExplanation(at: point, size) }
                }
            }
        }
    }

    // the (?) text for the tape: the header explains the columns, a row explains that one trade
    private func tapeExplanation(at point: CGPoint, _ size: CGSize) -> Hint {
        let index = Int(point.y / theme.layout.domRowHeight)
        // the size column is the right part of the row, the time takes the rest
        let onSize = point.x > size.width * 0.55
        let shown = Array(tape.prefix(max(1, Int(size.height / theme.layout.domRowHeight) - 1)))
        // what a normal trade is right now, so a size can be called big or small. nil before any trade
        let sizes = shown.map(\.size).sorted()
        let median: Double? = sizes.isEmpty ? nil : sizes[sizes.count / 2]
        let clock = { (trade: Trade) in
            Date(timeIntervalSince1970: trade.timestamp / 1000)
                .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
        }
        if index == 0 {
            return onSize
                ? Hint(
                    "Size column: how much \(coin) changed hands in each trade, converted from the exchange's contracts to the coin. Its colour is the aggressor: buy colour means a buyer paid the ask, sell colour means a seller hit the bid.\(median.map { " The median trade on screen is \(quantity($0)) \(coin)." } ?? "")",
                    example: "Strong: several prints of 10× the median or more, same colour, within a second or two, and the book on that side doesn't refill. Someone big is taking liquidity. Weak: a stream of tiny prints far under the median, small bots and noise, it tells you nothing."
                )
                : Hint(
                    "Time column: when each trade happened, newest on top. The exchange's own timestamp, shown in your time zone. Every row is one fill on this market.",
                    example: "Calm: a trade every second or two, the times step 11.50.39, 11.50.41, 11.50.44. Busy: ten rows with the same second, someone is sweeping the book. Look at the size and colour of that burst to see who's in a hurry."
                )
        }
        guard index - 1 < shown.count else {
            return Hint(
                "Tape: every trade on this same market, newest on top. Rows fill in as trades arrive.",
                example: "A quiet venue fills slowly. If it stays empty for minutes, check the market's dot in the bar at the bottom."
            )
        }
        let trade = shown[index - 1]
        let price = format(trade.price)
        let buy = trade.side == .buy
        if onSize {
            // a row exists, so the tape isn't empty and the median is known
            let ratio = trade.size / median!
            let multiple = String(format: "%.1f", ratio)
            let (word, book, other) = buy ? ("buy", "asks above", "sells") : ("sell", "bids under", "buys")
            return Hint(
                "\(quantity(trade.size)) \(coin) at \(price), about $\(usd(trade.quote)), \(multiple)× the median trade on screen. Taken at market: a \(buy ? "buyer crossed the spread and lifted the ask" : "seller crossed the spread and hit the bid"), so it removed \(quantity(trade.size)) \(coin) from the \(buy ? "asks" : "bids") at \(price).",
                example: ratio >= 3
                    ? "This is a big \(word), \(multiple)× the median. Strong: more like it in the same second and the \(book) \(price) shrink without coming back, someone is pushing. Weak: it stays alone, then \(other) take over and the \(book) \(price) refill. One big print isn't a trend."
                    : "This is \(ratio < 1 ? "a small" : "an ordinary") \(word), \(multiple)× the median, noise on its own. What would matter: \(word)s of 3× the median or more (from \(quantity(median! * 3)) \(coin)) several in one second, with the \(book) the price emptying.\(ratio < 1 ? " A long stream of tiny prints like this one is mostly bots." : "")"
            )
        }
        let second = Int(trade.timestamp / 1000)
        let burst = shown.filter { Int($0.timestamp / 1000) == second }
        let burstBuys = burst.filter { $0.side == .buy }.count
        let burstSells = burst.count - burstBuys
        let ago = max(0, Date().timeIntervalSince1970 - trade.timestamp / 1000)
        return Hint(
            "\(clock(trade)), \(ago < 60 ? String(format: "%.1fs", ago) : "\(Int(ago / 60))m") ago, the exchange's timestamp in your time zone. A \(buy ? "buy" : "sell") of \(quantity(trade.size)) \(coin) at \(price). \(burst.count) trade\(burst.count == 1 ? "" : "s") on screen happened in that same second, \(burstBuys) buy\(burstBuys == 1 ? "" : "s") and \(burstSells) sell\(burstSells == 1 ? "" : "s").",
            example: "Calm: one or two trades per second, both colours mixed, nobody in a hurry. Aggressive: ten or more in one second, mostly one colour, like a burst of sells at the same time as the bids under the price empty out. That's a market order sweeping the book."
        )
    }

    // the venue's own tick: the smallest gap between two levels. a book at $0.10 cannot be read in
    // $25 rows, the whole thing would land on one line
    private var step: Double {
        let prices = (book.bids.map(\.price) + book.asks.map(\.price)).sorted()
        let gaps = zip(prices, prices.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        return gaps.min() ?? max(1e-9, (book.mid ?? 1) * 1e-5)
    }

    private var decimals: Int {
        max(0, -Int(floor(log10(step))))
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).locale(Locale(identifier: "en_US")))
    }

    // the rows on screen, one venue tick each: the row nearest the mid in the middle, `half` above and below.
    // the left and right columns are `side` wide, the prices sit between them with a gutter either side
    private func grid(_ size: CGSize, _ step: Double) -> (centerKey: Int, half: Int, side: Double)? {
        guard let mid = book.mid else { return nil }
        // as wide as the mid's own label (77,351.70 has its comma and decimals), plus 12 of air each side
        let priceWidth = Double(max(7, format(mid).count)) * (theme.font.size - 1) * 0.62 + 24
        return (
            Int((mid / step).rounded()),
            max(2, (Int(size.height / theme.layout.domRowHeight) - 1) / 2),
            max(20, (size.width - priceWidth) / 2)
        )
    }

    // one row per level. rounded to the nearest row, the same as the center: the step comes from
    // float gaps (0.0999.. or 0.1000..1), and flooring put every level a row low when it ran high
    private func key(_ price: Double, _ step: Double) -> Int {
        Int((price / step).rounded())
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let step = step
        guard size.width > 40, size.height > 20, let grid = grid(size, step) else { return }
        let rowHeight = theme.layout.domRowHeight

        var bids: [Int: Double] = [:]
        var asks: [Int: Double] = [:]
        for level in book.bids { bids[key(level.price, step), default: 0] += level.size }
        for level in book.asks { asks[key(level.price, step), default: 0] += level.size }

        let rows = (-grid.half...grid.half).reversed().map { offset -> (key: Int, bid: Double, ask: Double) in
            let key = grid.centerKey + offset
            return (key, bids[key] ?? 0, asks[key] ?? 0)
        }
        let largest = max(1, rows.map { max($0.bid, $0.ask) }.max() ?? 1)
        let side = grid.side
        let colors = theme.colors
        func label(_ text: String, color: Color, weight: Font.Weight = .regular) -> Text {
            Text(text).font(theme.mono(-1, weight: weight)).foregroundStyle(color)
        }
        func hairline(_ y: Double, _ from: Double, _ to: Double, _ color: Color) {
            context.fill(Path(CGRect(x: from, y: y, width: to - from, height: 1)), with: .color(color))
        }

        // the price column is ruled off from the two sides like a ledger
        context.fill(Path(CGRect(x: side, y: 0, width: 1, height: size.height)), with: .color(colors.grid.color))
        context.fill(Path(CGRect(x: size.width - side - 1, y: 0, width: 1, height: size.height)), with: .color(colors.grid.color))

        for (index, row) in rows.enumerated() {
            let y = Double(index) * rowHeight
            let mid = row.key == grid.centerKey
            // every tenth tick is a round price, a faint line under it gives the eye somewhere to count from
            if row.key % 10 == 0 && !mid {
                hairline(y + rowHeight - 1, 0, size.width, colors.grid.color)
            }
            if mid {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(colors.domCurrentRow.color))
                hairline(y, 0, size.width, colors.accent.color.opacity(0.55))
                hairline(y + rowHeight - 1, 0, size.width, colors.accent.color.opacity(0.55))
            }
            // bars grow out from the price column, inset so neighbouring rows stay apart
            if theme.show.domBars && row.bid > 0 {
                let width = side * row.bid / largest
                context.fill(Path(CGRect(x: side - width, y: y + 3, width: width, height: rowHeight - 6)), with: .color(colors.domBuyBar.color))
            }
            if theme.show.domBars && row.ask > 0 {
                let width = side * row.ask / largest
                context.fill(Path(CGRect(x: size.width - side, y: y + 3, width: width, height: rowHeight - 6)), with: .color(colors.domSellBar.color))
            }
            if row.bid > 0 {
                context.draw(label(quantity(row.bid), color: colors.buy.color), at: CGPoint(x: side - 8, y: y + rowHeight / 2), anchor: .trailing)
            }
            if row.ask > 0 {
                context.draw(label(quantity(row.ask), color: colors.sell.color), at: CGPoint(x: size.width - side + 8, y: y + rowHeight / 2), anchor: .leading)
            }
            // prices outside the book are the empty rows between the two sides, the mid row is set in brass
            let inBook = row.bid > 0 || row.ask > 0 || mid
            context.draw(
                label(
                    format(Double(row.key) * step),
                    color: mid ? colors.accent.color : inBook ? colors.text.color : colors.muted.color.opacity(0.7),
                    weight: mid ? .semibold : .regular
                ),
                at: CGPoint(x: size.width / 2, y: y + rowHeight / 2),
                anchor: .center
            )
        }
    }

    // the (?) text for the row and column under the cursor
    private func explanation(at point: CGPoint, _ size: CGSize) -> Hint? {
        let step = step
        guard let grid = grid(size, step), let bestBid = book.bids.first, let bestAsk = book.asks.first else { return nil }
        let row = grid.centerKey + grid.half - Int(point.y / theme.layout.domRowHeight)
        let price = format(Double(row) * step)
        let bid = book.bids.filter { key($0.price, step) == row }.map(\.size).reduce(0, +)
        let ask = book.asks.filter { key($0.price, step) == row }.map(\.size).reduce(0, +)
        let ticks = abs(row - grid.centerKey)
        let away = ticks == 0 ? "on the mid row" : "\(ticks) tick\(ticks == 1 ? "" : "s") from the mid"
        let spread = format(bestAsk.price - bestBid.price)

        // the empty prices around this row, inside what's on screen: a hole the price can fall through
        let filled = Set((book.bids + book.asks).map { key($0.price, step) })
        var low = row, high = row
        while low - 1 >= grid.centerKey - grid.half, !filled.contains(low - 1) { low -= 1 }
        while high + 1 <= grid.centerKey + grid.half, !filled.contains(high + 1) { high += 1 }
        let gap = high - low + 1
        let gapText = "\(gap) empty price\(gap == 1 ? "" : "s") in a row here (\(format(Double(low) * step)) to \(format(Double(high) * step)))"

        // a level only matters next to the others: how it compares to the average on its side
        func compare(_ value: Double, _ side: [BookLevel], _ name: String) -> String {
            let total = side.map(\.size).reduce(0, +)
            let average = total / Double(side.count)
            return "That's \(String(format: "%.1f", value / average))× the average \(name) (\(quantity(average))) and \(Int((value / total * 100).rounded()))% of all \(name)s in the book"
        }

        if point.x < grid.side {
            if bid > 0 {
                return Hint(
                    "Bid: \(quantity(bid)) \(coin) waiting to buy at \(price), \(away). \(compare(bid, book.bids, "bid")). Resting orders only trade when someone sells into them at market. The bar is this size against the biggest level on screen.",
                    example: "Good for buyers: price drops to \(price), the tape prints sells there, and this \(quantity(bid)) stays or refills. It's absorbing the selling, a bounce is likely. Bad: it shrinks to nothing while the tape shows no sells at \(price). It was pulled, the support was never real. Small levels (under the average) don't hold anything up; only sizes several times the average do."
                )
            }
            if row > grid.centerKey {
                return Hint(
                    "Bids, orders waiting to buy, only rest below the price, so this side is empty above the mid. The asks above are on the right.",
                    example: "If a bid ever shows up here, above the best ask, the book has crossed: one exchange update is late, it fixes itself on the next one."
                )
            }
            return Hint(
                "No bid at \(price), \(away). \(gapText.prefix(1).uppercased() + gapText.dropFirst()).",
                example: "Good: sizes on most prices under the mid, a thick book, price walks down slowly and sellers have to work. Bad: a long run of empty prices under the mid (this one is \(gap) long). One big market sell drops straight through it, so moves through gaps are fast."
            )
        }
        if point.x > size.width - grid.side {
            if ask > 0 {
                return Hint(
                    "Ask: \(quantity(ask)) \(coin) waiting to sell at \(price), \(away). \(compare(ask, book.asks, "ask")). Resting orders only trade when someone buys into them at market. The bar is this size against the biggest level on screen.",
                    example: "Good for sellers: price rises to \(price), the tape prints buys there, and this \(quantity(ask)) stays or refills. It's a ceiling, buyers get absorbed. Bad for sellers (good for buyers): it disappears with no buys on the tape at \(price). It was pulled, and price can pop through. Small asks (under the average) don't cap anything."
                )
            }
            if row < grid.centerKey {
                return Hint(
                    "Asks, orders waiting to sell, only rest above the price, so this side is empty below the mid. The bids below are on the left.",
                    example: "If an ask ever shows up here, below the best bid, the book has crossed: one exchange update is late, it fixes itself on the next one."
                )
            }
            return Hint(
                "No ask at \(price), \(away). \(gapText.prefix(1).uppercased() + gapText.dropFirst()).",
                example: "Good for buyers: empty prices above the mid, like these \(gap), let a few market buys lift price quickly. Bad for buyers: asks stacked on every price above, each one has to be bought out, so price grinds."
            )
        }
        if row == grid.centerKey {
            return Hint(
                "Mid row: the price nearest halfway between the best bid (\(format(bestBid.price))) and the best ask (\(format(bestAsk.price))). The gap between them is the spread, \(spread) now. A market buy pays the ask, a market sell gets the bid.",
                example: "Good: a spread of one tick (\(format(step))), the tightest there is. The book is liquid and a market order costs almost nothing. Bad: the spread opens to many ticks, makers pulled their orders, the next market order slips and price can jump."
            )
        }
        let empty = bid == 0 && ask == 0
        return Hint(
            "\(price), \(away): one row per tick, the smallest price step this exchange allows (\(format(step))). \(empty ? "Dim: no order rests here, \(gapText)." : "Bright: orders rest here.") The book shows the nearest \(book.bids.count) bids and \(book.asks.count) asks.",
            example: "Good: bright prices with sizes next to each other near the mid, every tick has someone willing to trade. Bad: long dim stretches like a gap of 10 prices, price can skip all of it in one move and a stop fills far from where it was placed."
        )
    }

    private func tapeView(rows: Int) -> some View {
        let rowHeight = theme.layout.domRowHeight
        let shown = tape.prefix(max(1, rows - 1))
        return VStack(spacing: 0) {
            // the header is exactly one row tall, the (?) text counts rows from it
            HStack(spacing: 4) {
                CapsLabel("Time", theme: theme).frame(maxWidth: .infinity, alignment: .leading)
                CapsLabel("Size", theme: theme)
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .overlay(alignment: .bottom) { theme.colors.border.color.frame(height: 1) }

            ForEach(Array(shown.enumerated()), id: \.offset) { _, trade in
                HStack(spacing: 4) {
                    Text(Date(timeIntervalSince1970: trade.timestamp / 1000).formatted(date: .omitted, time: .standard))
                        .foregroundStyle(theme.colors.muted.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // the size is never cut, the time gives way: 0.00010 btc must read in full
                    Text(quantity(trade.size))
                        .foregroundStyle((trade.side == .buy ? theme.colors.buy : theme.colors.sell).color)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .frame(height: rowHeight)
            }
            Spacer(minLength: 0)
        }
        .font(theme.mono(-1))
        .clipped()
    }
}
