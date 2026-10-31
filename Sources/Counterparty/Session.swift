import CounterpartyKit
import Foundation
import os

// the live order book of one market, the ladder you meditate on: sizes come and go without a trade
@MainActor @Observable
final class BookModel {
    private(set) var book: Book?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watched: String?
    // contract values, to show every venue's book in the coin
    @ObservationIgnored private let catalogs: Catalogs

    init(catalogs: Catalogs) {
        self.catalogs = catalogs
    }

    // nil stops the stream, a market starts it
    func watch(_ market: String?) {
        guard market != watched else { return }
        watched = market
        task?.cancel()
        task = nil
        book = nil
        error = nil
        guard let market else { return }
        task = startBook(
            market: market,
            catalogs: catalogs,
            onBook: { [weak self] book in self?.book = book },
            onStatus: { [weak self] error in self?.error = error }
        )
    }

    func stop() {
        task?.cancel()
        task = nil
        watched = nil
        book = nil
    }
}

// one open coin: its own sockets, chart and book. every tab keeps streaming while another is shown,
// so switching back is instant
@MainActor @Observable
final class CoinSession: Identifiable {
    let id = UUID()
    let coin: String
    let markets: [String]
    let indicator = IndicatorModel()
    let book: BookModel
    // the tape: the newest trades of each market, newest last. kept per market so a quiet venue's
    // tape isn't pushed out by binance and bybit
    private(set) var tapes: [String: [Trade]] = [:]
    private(set) var statuses: [String: MarketStatus] = [:]
    // what the header, the tab and the market bar show, refreshed twice a second
    private(set) var price: Double?
    // the price against the previous bar's close, nil until there's a previous bar
    private(set) var rising: Bool?
    private(set) var tradeCounts: [String: Int] = [:]
    // these change on every trade, observing them would redraw the window per trade
    @ObservationIgnored private var counts: [String: Int] = [:]
    @ObservationIgnored private var lastPrice: Double?
    @ObservationIgnored private var feed: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    // sockets drop trades in here from their own threads, the ticker takes them on the main thread
    // ten times a second, instead of one main-thread hop per socket message
    @ObservationIgnored private let inbox = OSAllocatedUnfairLock(initialState: [Trade]())


    init(coin: String, catalogs: Catalogs) {
        self.coin = coin
        markets = catalogs.markets(for: coin)
        book = BookModel(catalogs: catalogs)
        let inbox = inbox
        feed = startFeed(
            markets: markets,
            catalogs: catalogs,
            onTrades: { trades in inbox.withLock { $0 += trades } },
            onStatus: { [weak self] markets, status in
                for market in markets { self?.statuses[market] = status }
            }
        )
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let trades = inbox.withLock { pending in
                    var taken: [Trade] = []
                    swap(&taken, &pending)
                    return taken
                }
                if !trades.isEmpty { receive(trades) }
                tick += 1
                if tick % 5 == 0 { publish() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // a tab that is closed stops its sockets
    func close() {
        feed?.cancel()
        ticker?.cancel()
        book.stop()
    }

    // only when the bars aren't in this timeframe yet, so switching tabs doesn't reload
    func loadHistory(timeframe: Int) async {
        guard indicator.timeframe != timeframe else { return }
        await indicator.load(timeframe: timeframe, markets: markets)
    }

    private func receive(_ trades: [Trade]) {
        var byMarket: [String: [Trade]] = [:]
        for trade in trades where !trade.liquidation {
            counts[trade.market, default: 0] += 1
            lastPrice = trade.price
            byMarket[trade.market, default: []].append(trade)
        }
        indicator.add(trades)
        for (market, new) in byMarket {
            var tape = tapes[market, default: []] + new
            if tape.count > 60 { tape.removeFirst(tape.count - 60) }
            tapes[market] = tape
        }
    }

    // only writes what changed, every write to an observed value redraws whatever reads it
    private func publish() {
        if price != lastPrice { price = lastPrice }
        if tradeCounts != counts { tradeCounts = counts }
        let direction = indicator.previousClose.flatMap { close in lastPrice.map { $0 >= close } }
        if rising != direction { rising = direction }
    }
}

// the open tabs, and the product lists every tab's markets come from
@MainActor @Observable
final class Workspace {
    // nil until every exchange's product list is read
    private(set) var catalogs: Catalogs?
    private(set) var coins: [Coin] = []
    private(set) var tabs: [CoinSession] = []
    private(set) var selected: CoinSession?
    // the coin search, and whether its pick opens a new tab or replaces the current one
    var search: SearchMode?

    enum SearchMode: Identifiable {
        case replace, newTab
        var id: Self { self }
    }

    private static let tabsKey = "tabs"
    private static let selectedKey = "selectedTab"

    func start() async {
        guard catalogs == nil else { return }
        let catalogs = await loadCatalogs()
        self.catalogs = catalogs
        coins = catalogs.coins

        // reopen last session's tabs, a coin that lost all its perps since is left out
        UserDefaults.standard.register(defaults: [Self.tabsKey: ["BTC"], Self.selectedKey: "BTC"])
        let saved = UserDefaults.standard.stringArray(forKey: Self.tabsKey)!
        let known = Set(coins.map(\.symbol))
        tabs = saved.filter(known.contains).map { CoinSession(coin: $0, catalogs: catalogs) }
        if tabs.isEmpty, let first = coins.first { tabs = [CoinSession(coin: first.symbol, catalogs: catalogs)] }
        let selectedCoin = UserDefaults.standard.string(forKey: Self.selectedKey)!
        selected = tabs.first { $0.coin == selectedCoin } ?? tabs.first
    }

    // every tab's history in the current timeframe, the shown one first, so switching tabs never waits on
    // aggr's history server (which can take 30s+ per request). one at a time to go easy on it
    func prefetch(timeframe: Int) async {
        let order = (selected.map { [$0] } ?? []) + tabs.filter { $0 !== selected }
        for session in order {
            if Task.isCancelled { return }
            await session.loadHistory(timeframe: timeframe)
        }
    }

    // a coin that's already open is switched to instead of opened twice
    func open(_ coin: String, mode: SearchMode) {
        guard let catalogs else { return }
        if let existing = tabs.first(where: { $0.coin == coin }) {
            selected = existing
        } else if mode == .replace, let current = selected, let index = tabs.firstIndex(where: { $0 === current }) {
            current.close()
            let session = CoinSession(coin: coin, catalogs: catalogs)
            tabs[index] = session
            selected = session
        } else {
            let session = CoinSession(coin: coin, catalogs: catalogs)
            tabs.append(session)
            selected = session
        }
        save()
    }

    func select(_ session: CoinSession) {
        selected = session
        save()
    }

    // ⌘1 to ⌘9 like safari, ⌘9 is always the last tab
    func select(number: Int) {
        guard !tabs.isEmpty else { return }
        select(number == 9 ? tabs[tabs.count - 1] : tabs[min(number, tabs.count) - 1])
    }

    func selectNeighbor(_ step: Int) {
        guard let selected, let index = tabs.firstIndex(where: { $0 === selected }) else { return }
        select(tabs[(index + step + tabs.count) % tabs.count])
    }

    // the last tab stays, an empty window has nothing to show
    func close(_ session: CoinSession) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === session }) else { return }
        session.close()
        tabs.remove(at: index)
        if selected === session { selected = tabs[min(index, tabs.count - 1)] }
        save()
    }

    func move(_ session: CoinSession, before target: CoinSession) {
        guard session !== target, let from = tabs.firstIndex(where: { $0 === session }) else { return }
        tabs.remove(at: from)
        let to = tabs.firstIndex(where: { $0 === target })!
        tabs.insert(session, at: to)
        save()
    }

    private func save() {
        UserDefaults.standard.set(tabs.map(\.coin), forKey: Self.tabsKey)
        if let selected { UserDefaults.standard.set(selected.coin, forKey: Self.selectedKey) }
    }
}
