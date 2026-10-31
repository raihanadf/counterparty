import Foundation

// themes that ship with the app. each one is the same kind of overlay a theme file is,
// laid over the default, so they go through the same checks as an imported file

extension Theme {
    static let builtins: [Theme] = [standard] + [light, monochrome, monochromeLight, tradingView, bybit, highContrast, focus, atelier].map {
        do {
            return try Theme.load(Data($0.utf8))
        } catch {
            preconditionFailure("built-in theme doesn't load: \(error.localizedDescription)")
        }
    }
}

private let light = """
{
  "name": "Light",
  "appearance": "light",
  "colors": {
    "background": "#F7F8FA", "panel": "#FFFFFF", "border": "#E1E4EA", "text": "#1C2230", "muted": "#6B7383",
    "accent": "#2563EB", "buy": "#0E9F6E", "sell": "#E02424",
    "candleUp": "#0E9F6E", "candleDown": "#E02424", "candleUpBorder": "#0E9F6E", "candleDownBorder": "#E02424",
    "wickUp": "#0E9F6E", "wickDown": "#E02424",
    "volumeUp": "#0E9F6E66", "volumeDown": "#E0242466", "deltaUp": "#0E9F6E", "deltaDown": "#E02424",
    "liquidationBuy": "#C026D3", "liquidationSell": "#D97706", "cvd": "#2563EB",
    "grid": "#0000000F", "crosshair": "#00000059",
    "domBuyBar": "#0E9F6E40", "domSellBar": "#E0242440", "domCurrentRow": "#2563EB1A",
    "statusLive": "#0E9F6E", "statusPending": "#D97706", "statusDown": "#E02424"
  }
}
"""

// greys only, buys light and sells dark
private let monochrome = """
{
  "name": "Monochrome",
  "colors": {
    "background": "#0A0A0A", "panel": "#121212", "border": "#262626", "text": "#EDEDED", "muted": "#8A8A8A",
    "accent": "#EDEDED", "buy": "#EDEDED", "sell": "#7A7A7A",
    "candleUp": "#E0E0E0", "candleDown": "#5C5C5C", "candleUpBorder": "#E0E0E0", "candleDownBorder": "#9E9E9E",
    "wickUp": "#BDBDBD", "wickDown": "#9E9E9E",
    "volumeUp": "#FFFFFF40", "volumeDown": "#FFFFFF1A", "deltaUp": "#D6D6D6", "deltaDown": "#5C5C5C",
    "liquidationBuy": "#FFFFFF", "liquidationSell": "#8A8A8A", "cvd": "#FFFFFF",
    "grid": "#FFFFFF0A", "crosshair": "#FFFFFF59", "priceTagText": "#000000",
    "domBuyBar": "#FFFFFF40", "domSellBar": "#FFFFFF1A", "domCurrentRow": "#FFFFFF14",
    "statusLive": "#EDEDED", "statusPending": "#8A8A8A", "statusDown": "#4D4D4D"
  }
}
"""

private let monochromeLight = """
{
  "name": "Monochrome Light",
  "appearance": "light",
  "colors": {
    "background": "#FAFAFA", "panel": "#FFFFFF", "border": "#E0E0E0", "text": "#141414", "muted": "#767676",
    "accent": "#141414", "buy": "#141414", "sell": "#8C8C8C",
    "candleUp": "#1F1F1F", "candleDown": "#B3B3B3", "candleUpBorder": "#1F1F1F", "candleDownBorder": "#8C8C8C",
    "wickUp": "#3D3D3D", "wickDown": "#8C8C8C",
    "volumeUp": "#00000040", "volumeDown": "#0000001A", "deltaUp": "#3D3D3D", "deltaDown": "#B3B3B3",
    "liquidationBuy": "#000000", "liquidationSell": "#8C8C8C", "cvd": "#000000",
    "grid": "#0000000D", "crosshair": "#00000059", "priceTagText": "#FFFFFF",
    "domBuyBar": "#00000033", "domSellBar": "#00000014", "domCurrentRow": "#0000000F",
    "statusLive": "#141414", "statusPending": "#8C8C8C", "statusDown": "#C4C4C4"
  }
}
"""

// tradingview's dark chart colors
private let tradingView = """
{
  "name": "TradingView",
  "colors": {
    "background": "#131722", "panel": "#1E222D", "border": "#2A2E39", "text": "#D1D4DC", "muted": "#787B86",
    "accent": "#2962FF", "buy": "#26A69A", "sell": "#EF5350",
    "candleUp": "#26A69A", "candleDown": "#EF5350", "candleUpBorder": "#26A69A", "candleDownBorder": "#EF5350",
    "wickUp": "#26A69A", "wickDown": "#EF5350",
    "volumeUp": "#26A69A80", "volumeDown": "#EF535080", "deltaUp": "#26A69A", "deltaDown": "#EF5350",
    "liquidationBuy": "#E040FB", "liquidationSell": "#FF9800", "cvd": "#2962FF",
    "grid": "#FFFFFF0A", "crosshair": "#9598A1", "priceTagText": "#FFFFFF",
    "domBuyBar": "#26A69A59", "domSellBar": "#EF535059", "domCurrentRow": "#2962FF26",
    "statusLive": "#26A69A", "statusPending": "#FF9800", "statusDown": "#EF5350"
  }
}
"""

// bybit's dark app, with its orange accent
private let bybit = """
{
  "name": "Bybit",
  "colors": {
    "background": "#0B0B0F", "panel": "#16161A", "border": "#25252B", "text": "#EAECEF", "muted": "#81858C",
    "accent": "#F7A600", "buy": "#20B26C", "sell": "#EF454A",
    "candleUp": "#20B26C", "candleDown": "#EF454A", "candleUpBorder": "#20B26C", "candleDownBorder": "#EF454A",
    "wickUp": "#20B26C", "wickDown": "#EF454A",
    "volumeUp": "#20B26C80", "volumeDown": "#EF454A80", "deltaUp": "#20B26C", "deltaDown": "#EF454A",
    "liquidationBuy": "#D946EF", "liquidationSell": "#F7A600", "cvd": "#F7A600",
    "grid": "#FFFFFF0A", "crosshair": "#FFFFFF4D", "priceTagText": "#FFFFFF",
    "domBuyBar": "#20B26C59", "domSellBar": "#EF454A59", "domCurrentRow": "#F7A6001F",
    "statusLive": "#20B26C", "statusPending": "#F7A600", "statusDown": "#EF454A"
  }
}
"""

// pure black, full-strength colors and a bigger font
private let highContrast = """
{
  "name": "High Contrast",
  "font": { "size": 13 },
  "colors": {
    "background": "#000000", "panel": "#000000", "border": "#FFFFFF59", "text": "#FFFFFF", "muted": "#C7C7C7",
    "accent": "#00E5FF", "buy": "#00FF85", "sell": "#FF3B3B",
    "candleUp": "#00FF85", "candleDown": "#FF3B3B", "candleUpBorder": "#00FF85", "candleDownBorder": "#FF3B3B",
    "wickUp": "#FFFFFF", "wickDown": "#FFFFFF",
    "volumeUp": "#00FF85B3", "volumeDown": "#FF3B3BB3", "deltaUp": "#00FF85", "deltaDown": "#FF3B3B",
    "liquidationBuy": "#FF4CF3", "liquidationSell": "#FFD000", "cvd": "#00E5FF",
    "grid": "#FFFFFF1F", "crosshair": "#FFFFFFB3", "priceTagText": "#000000",
    "domBuyBar": "#00FF8573", "domSellBar": "#FF3B3B73", "domCurrentRow": "#FFFFFF2E",
    "statusLive": "#00FF85", "statusPending": "#FFD000", "statusDown": "#FF3B3B"
  }
}
"""

// just price and flow: no volume panels, no grid, no market bar
private let focus = """
{
  "name": "Focus",
  "font": { "family": "Menlo", "size": 13 },
  "colors": {
    "background": "#000000", "panel": "#0A0A0A", "border": "#1F1F1F", "accent": "#F5A524",
    "candleUp": "#26A69A", "candleDown": "#EF5350", "candleUpBorder": "#26A69A", "candleDownBorder": "#EF5350",
    "wickUp": "#26A69A", "wickDown": "#EF5350", "domBuyBar": "#26A69A55", "domSellBar": "#EF535055"
  },
  "show": {
    "headerSubtitle": false, "marketsBar": false, "grid": false, "volume": false, "delta": false, "cvd": false
  },
  "layout": { "domWidth": 360, "domRowHeight": 18, "candleWidth": 0.5 }
}
"""

// warm graphite and bone, one muted brass accent: monochrome with a hand-thrown feel
private let atelier = """
{
  "name": "Atelier",
  "colors": {
    "background": "#0E0D0C", "panel": "#161513", "border": "#2A2724", "text": "#EAE4D9", "muted": "#8C857A",
    "accent": "#C2A878", "buy": "#EDE6D8", "sell": "#8C857A",
    "candleUp": "#EDE6D8", "candleDown": "#7A746B", "candleUpBorder": "#EDE6D8", "candleDownBorder": "#918A7F",
    "wickUp": "#EDE6D8", "wickDown": "#918A7F",
    "volumeUp": "#EDE6D84D", "volumeDown": "#7A746B80", "deltaUp": "#EDE6D8", "deltaDown": "#7A746B",
    "liquidationBuy": "#B9765A", "liquidationSell": "#C2A878", "cvd": "#C2A878",
    "grid": "#EAE4D90A", "crosshair": "#EAE4D959", "priceTagText": "#0E0D0C",
    "domBuyBar": "#EDE6D866", "domSellBar": "#6B655B40", "domCurrentRow": "#C2A8781F",
    "statusLive": "#EDE6D8", "statusPending": "#C2A878", "statusDown": "#B9765A"
  }
}
"""
