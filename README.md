# Counterparty

A native macOS app (Swift, SwiftUI, no dependencies) that shows live BTC order flow pulled the same way [aggr.trade](https://aggr.trade) does it, with two views you can switch on and off from the toolbar:

- **Indicator**: aggr's default chart. Price candles averaged across markets, volume with delta, liquidations and CVD. Pinch to zoom, drag to scroll back, double click to jump to the live bar, hover for the bar's values.
- **DOM**: a price ladder showing how much was bought and sold at each level since the app opened, plus liquidations and delta. aggr only streams trades, not order books, so this is the executed side of the ladder.

## Data

The data is the same as aggr's default BTC setup (16 markets, `markets` in `Sources/CounterpartyKit/Exchanges.swift`):

| What | Where it comes from |
| --- | --- |
| Product lists (contract sizes, inverse/linear) | exchange REST endpoints through aggr's proxy `https://cors.aggr.trade/<url>` |
| Chart history | `https://api.aggr.trade/historical/{from}/{to}/{timeframe ms}/{markets}` |
| Live trades and liquidations | each exchange's public websocket, with the same subscriptions as aggr's worker |

Sizes are converted to BTC the same way aggr does it (inverse contracts divided by price, OKX and Binance coin-margined contract values), and volume is shown in USD (`price × size`).

BitMEX is in aggr's default list, but its product endpoint now returns nothing since the exchange shut down, so those two markets show as unavailable (aggr skips them too).

The bar at the bottom shows every market's connection state and how many trades came in. Hover a dot to see why a market is down.

## Run

Needs macOS 14 or newer and Xcode (or the Swift 6 toolchain).

```sh
swift run Counterparty      # run from source
./bundle.sh                 # build a release Counterparty.app
open Counterparty.app
```

You can also open `Package.swift` in Xcode.

## Code

- `Sources/CounterpartyKit`: exchange adapters (`Exchanges.swift`), feed with reconnect (`Feed.swift`), websocket over Network.framework (`Socket.swift`), aggr history client (`History.swift`).
- `Sources/Counterparty`: the app, the chart (`Indicator.swift`) and the ladder (`Dom.swift`).

## DNS blocking

Some ISPs (Indonesia's internetpositif) hijack exchange domains through DNS, so the system resolver hands out a block page instead of the exchange. Exchange websockets therefore look up their address through Cloudflare's DNS-over-HTTPS (`https://1.1.1.1/dns-query`) and connect to it directly, with TLS and the HTTP `Host` still set to the exchange's real name, so certificates are checked as usual. Product lists and history go through aggr's own servers, which aren't blocked. Nothing changes system-wide.
