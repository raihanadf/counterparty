import Foundation

// one market's bar from aggr's history api, volumes in usd like aggr stores them
public struct HistoryBar: Sendable {
    // bar start, unix seconds
    public let time: Int
    public let market: String
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let vbuy: Double
    public let vsell: Double
    public let lbuy: Double
    public let lsell: Double
}

private struct HistoryResponse: Decodable {
    let format: String
    let columns: [String: Int]
    let results: [JSON]
}

struct HistoryError: LocalizedError {
    let errorDescription: String?
}

// same request aggr's chart makes: /historical/{from ms}/{to ms}/{timeframe ms}/{markets joined by +}
public func fetchHistory(markets: [String], timeframe: Int, from: Date, to: Date) async throws -> [HistoryBar] {
    let joined = markets.joined(separator: "+").addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.")))!
    let url = URL(string: "https://api.aggr.trade/historical/\(Int(from.timeIntervalSince1970 * 1000))/\(Int(to.timeIntervalSince1970 * 1000))/\(timeframe * 1000)/\(joined)")!
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw HistoryError(errorDescription: "history answered \(http.statusCode): \(String(decoding: data, as: UTF8.self))")
    }
    let history = try JSONDecoder().decode(HistoryResponse.self, from: data)
    guard history.format == "point" else { throw HistoryError(errorDescription: "history came in format \(history.format)") }

    return try history.results.map { row in
        // closed bars are arrays in seconds, the pending bar of each market is an object in milliseconds
        let pending = row["market"] != nil
        let field = { (name: String) -> JSON? in
            pending ? row[name] : history.columns[name].flatMap { row[$0] }
        }
        guard let time = field("time")?.number, let market = field("market")?.string,
              let open = field("open")?.number, let high = field("high")?.number,
              let low = field("low")?.number, let close = field("close")?.number
        else { throw HistoryError(errorDescription: "history row without price: \(row)") }
        let seconds = Int(pending ? time / 1000 : time)
        return HistoryBar(
            time: seconds - seconds % timeframe,
            market: market,
            open: open,
            high: high,
            low: low,
            close: close,
            // empty volume and liquidation columns come as null
            vbuy: field("vbuy")?.number ?? 0,
            vsell: field("vsell")?.number ?? 0,
            lbuy: field("lbuy")?.number ?? 0,
            lsell: field("lsell")?.number ?? 0
        )
    }
}
