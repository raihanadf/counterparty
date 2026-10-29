# Counterparty

A native macOS app (Swift, SwiftUI, no dependencies) that shows live order flow of crypto perpetual futures, pulled the same way [aggr.trade](https://aggr.trade) does it, for any coin, with two views you can switch on and off:

- **Indicator**: aggr's default chart. Price candles averaged across markets, volume with delta, liquidations and CVD.
- **DOM**: a price ladder showing how much was bought and sold at each level since the coin was opened, plus liquidations and delta. aggr only streams trades, not order books, so this is the executed side of the ladder.

## Coins

Click the coin name in the header (or ⌘K) to search every coin that has a perp: BTC, ETH, SOL, memecoins, small caps. A coin gets every perp these exchanges list for it, and nothing else (no spot):

| Exchange | Perps |
| --- | --- |
| Binance Futures | `{coin}usdt`, `{coin}usd_perp` (coin margined) |
| Bitfinex | `{coin}F0:USTF0` |
| Bybit | `{coin}USDT`, `{coin}USD` (inverse) |
| Deribit | `{coin}-PERPETUAL` (btc and eth), `{coin}_USDC-PERPETUAL` |
| OKX | `{coin}-USDT-SWAP`, `{coin}-USD-SWAP` (inverse) |

For BTC that's the perps from aggr's default market set, plus Deribit's USDC perp. aggr's defaults also had BitMEX, which shut down, and Coinbase, whose perps aren't in the product list aggr's proxy serves. Coins with a contract multiplier in the name (Bybit's `1000PEPE`) are their own coin, since their price is 1000× the coin's.

aggr's server only keeps history for the bigger coins. Other coins start with an empty chart that fills from live trades.

## Chart controls

Works like Bybit's (TradingView) chart:

| Gesture | Does |
| --- | --- |
| Two-finger swipe sideways, or drag | scroll through time |
| Two-finger swipe up/down, pinch, or mouse wheel | zoom around the pointer |
| Drag the price axis | stretch or squeeze prices (turns auto-scale off) |
| Drag vertically on the chart | move prices, once auto-scale is off |
| Drag the time axis | zoom |
| Double-click the price axis, or the **A** button | auto-scale back on |
| Double-click the chart, or two-finger double-tap | back to the newest bar, auto-scale, default zoom |
| **»** button | back to the newest bar |

Hovering shows a crosshair with the price and time on the axes, and the bar's values in the top-left.

## Data

| What | Where it comes from |
| --- | --- |
| Product lists (contract sizes, inverse/linear) | exchange REST endpoints through aggr's proxy `https://cors.aggr.trade/<url>`; Bybit directly, since the proxy only carries the first page of its 500+ perps |
| Chart history | `https://api.aggr.trade/historical/{from}/{to}/{timeframe ms}/{markets}` |
| Live trades and liquidations | each exchange's public websocket, with the same subscriptions as aggr's worker |

Sizes are converted to the coin the same way aggr does it (inverse contracts divided by price, OKX and Binance coin-margined contract values), and volume is shown in USD (`price × size`).

The bar at the bottom shows every market's connection state and how many trades came in. Hover a dot to see why a market is down.

## Themes

Settings (⌘,) imports a `.json` theme: colors, font, which parts are shown, and a few sizes. A theme only lists what it changes; anything left out keeps the default. Unknown keys and bad values are refused with the exact key in the error. Colors are `#rrggbb`, `#rrggbbaa`, `rgb()` or `rgba()`.

`Themes/default.json` is the full default theme (also exportable from Settings). `Themes/light.json` and `Themes/focus.json` are examples. When a theme hides the header, the View menu still has every switch (⌘K coin, ⌘1 indicator, ⌘2 DOM).

## Run

Needs macOS 14 or newer and Xcode (or the Swift 6 toolchain).

```sh
swift run Counterparty      # run from source
./bundle.sh                 # build a release Counterparty.app
open Counterparty.app
```

You can also open `Package.swift` in Xcode.

## Code

- `Sources/CounterpartyKit`: exchange adapters (`Exchanges.swift`), product lists, coins and the feed with reconnect (`Feed.swift`), websockets and https over Network.framework (`Socket.swift`), aggr history client (`History.swift`).
- `Sources/Counterparty`: the app (`App.swift`), chart data (`Indicator.swift`), the chart and its gestures (`Chart.swift`), the ladder (`Dom.swift`), the coin search (`CoinPicker.swift`), themes (`Theme.swift`, `Settings.swift`).
- `Assets/AppIcon.svg`: the app icon source, `AppIcon.png` is its 1024px render. `bundle.sh` turns it into the `.icns` macOS uses.

## DNS blocking

Some ISPs (Indonesia's internetpositif) hijack exchange domains through DNS, so the system resolver hands out a block page instead of the exchange. Exchange websockets and Bybit's product list therefore look up their address through Cloudflare's DNS-over-HTTPS (`https://1.1.1.1/dns-query`) and connect to it directly, with TLS and the HTTP `Host` still set to the exchange's real name, so certificates are checked as usual. The other product lists and history go through aggr's own servers, which aren't blocked. Nothing changes system-wide.
