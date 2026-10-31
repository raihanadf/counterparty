import AppKit
import SwiftUI

// everything the app's look is made of. a theme file is json with the same shape:
// every key is optional and keeps the default when left out, unknown keys and bad values are errors.

struct ThemeColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(hex: String) {
        self = try! ThemeColor.parse(hex)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            self = try ThemeColor.parse(text)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error.localizedDescription)")
        }
    }

    private init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    // "#rrggbb", "#rrggbbaa", "rgb(59, 202, 109)" or "rgba(59, 202, 109, 0.5)"
    private static func parse(_ text: String) throws -> ThemeColor {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            let digits = value.dropFirst()
            guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else {
                throw ThemeError("\"\(text)\" is not a color, use #rrggbb or #rrggbbaa")
            }
            let rgba = digits.count == 6 ? number << 8 | 0xFF : number
            return ThemeColor(
                red: Double(rgba >> 24 & 0xFF) / 255,
                green: Double(rgba >> 16 & 0xFF) / 255,
                blue: Double(rgba >> 8 & 0xFF) / 255,
                alpha: Double(rgba & 0xFF) / 255
            )
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let parts = value[value.index(after: open)..<value.index(before: value.endIndex)]
                .split(separator: ",")
                .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            let numbers = parts.compactMap { $0 }
            guard numbers.count == parts.count, numbers.count == 3 || numbers.count == 4,
                  numbers.prefix(3).allSatisfy({ (0...255).contains($0) }), numbers.count == 3 || (0...1).contains(numbers[3])
            else { throw ThemeError("\"\(text)\" is not a color, rgb takes 0-255 and alpha 0-1") }
            return ThemeColor(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: numbers.count == 4 ? numbers[3] : 1)
        }
        throw ThemeError("\"\(text)\" is not a color, use #rrggbb, #rrggbbaa, rgb() or rgba()")
    }

    func encode(to encoder: Encoder) throws {
        let byte = { (value: Double) in String(format: "%02X", Int((value * 255).rounded())) }
        var container = encoder.singleValueContainer()
        try container.encode("#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : ""))
    }
}

struct Theme: Codable, Equatable {
    enum Appearance: String, Codable {
        case dark, light
    }

    struct Font: Codable, Equatable {
        // a font installed on this mac, or "system-mono" for sf mono
        var family: String
        // base size of the dom and the numbers, labels scale from it
        var size: Double
    }

    struct Colors: Codable, Equatable {
        // window
        var background: ThemeColor
        var panel: ThemeColor
        var border: ThemeColor
        var text: ThemeColor
        var muted: ThemeColor
        // switches and the selected timeframe
        var accent: ThemeColor
        var buy: ThemeColor
        var sell: ThemeColor
        // chart
        var candleUp: ThemeColor
        var candleDown: ThemeColor
        var candleUpBorder: ThemeColor
        var candleDownBorder: ThemeColor
        var wickUp: ThemeColor
        var wickDown: ThemeColor
        var volumeUp: ThemeColor
        var volumeDown: ThemeColor
        var deltaUp: ThemeColor
        var deltaDown: ThemeColor
        var liquidationBuy: ThemeColor
        var liquidationSell: ThemeColor
        var cvd: ThemeColor
        var grid: ThemeColor
        var crosshair: ThemeColor
        var priceTagText: ThemeColor
        // dom: book size bars and the mid row
        var domBuyBar: ThemeColor
        var domSellBar: ThemeColor
        var domCurrentRow: ThemeColor
        // market connection dots
        var statusLive: ThemeColor
        var statusPending: ThemeColor
        var statusDown: ThemeColor
    }

    struct Show: Codable, Equatable {
        // header bar with the price and switches, the view menu still has every switch when it's hidden
        var header: Bool
        // the strip of open coins above the header, ⌘1-9 and the tabs menu still switch when it's hidden
        var tabs: Bool
        var headerPrice: Bool
        var headerSubtitle: Bool
        var marketsBar: Bool
        var legend: Bool
        var grid: Bool
        var priceAxis: Bool
        var timeAxis: Bool
        var candles: Bool
        var volume: Bool
        var delta: Bool
        var liquidations: Bool
        var cvd: Bool
        var lastPriceLine: Bool
        var crosshair: Bool
        // the size bars behind the book's numbers
        var domBars: Bool
    }

    struct Layout: Codable, Equatable {
        // width of the dom next to the chart, it takes the whole window when alone
        var domWidth: Double
        var domRowHeight: Double
        // candle body width as a fraction of the space between candles
        var candleWidth: Double
    }

    var name: String
    var appearance: Appearance
    var font: Font
    var colors: Colors
    var show: Show
    var layout: Layout

    // atelier: warm graphite and bone, one muted brass accent. monochrome with a hand-made feel,
    // so up and down read as light and shade instead of green and red
    static let standard = Theme(
        name: "Atelier",
        appearance: .dark,
        font: Font(family: "system-mono", size: 12),
        colors: Colors(
            background: ThemeColor(hex: "#0E0D0C"),
            panel: ThemeColor(hex: "#161513"),
            border: ThemeColor(hex: "#2A2724"),
            text: ThemeColor(hex: "#EAE4D9"),
            muted: ThemeColor(hex: "#8C857A"),
            accent: ThemeColor(hex: "#C2A878"),
            buy: ThemeColor(hex: "#EDE6D8"),
            sell: ThemeColor(hex: "#8C857A"),
            candleUp: ThemeColor(hex: "#EDE6D8"),
            candleDown: ThemeColor(hex: "#7A746B"),
            candleUpBorder: ThemeColor(hex: "#EDE6D8"),
            candleDownBorder: ThemeColor(hex: "#918A7F"),
            wickUp: ThemeColor(hex: "#EDE6D8"),
            wickDown: ThemeColor(hex: "#918A7F"),
            volumeUp: ThemeColor(hex: "#EDE6D84D"),
            volumeDown: ThemeColor(hex: "#7A746B80"),
            deltaUp: ThemeColor(hex: "#EDE6D8"),
            deltaDown: ThemeColor(hex: "#7A746B"),
            liquidationBuy: ThemeColor(hex: "#B9765A"),
            liquidationSell: ThemeColor(hex: "#C2A878"),
            cvd: ThemeColor(hex: "#C2A878"),
            grid: ThemeColor(hex: "#EAE4D90A"),
            crosshair: ThemeColor(hex: "#EAE4D959"),
            priceTagText: ThemeColor(hex: "#0E0D0C"),
            domBuyBar: ThemeColor(hex: "#EDE6D866"),
            domSellBar: ThemeColor(hex: "#6B655B40"),
            domCurrentRow: ThemeColor(hex: "#C2A8781F"),
            statusLive: ThemeColor(hex: "#EDE6D8"),
            statusPending: ThemeColor(hex: "#C2A878"),
            statusDown: ThemeColor(hex: "#B9765A")
        ),
        show: Show(
            header: true, tabs: true, headerPrice: true, headerSubtitle: true, marketsBar: true,
            legend: true, grid: true, priceAxis: true, timeAxis: true,
            candles: true, volume: true, delta: true, liquidations: true, cvd: true,
            lastPriceLine: true, crosshair: true,
            domBars: true
        ),
        layout: Layout(domWidth: 440, domRowHeight: 20, candleWidth: 0.7)
    )

    // monospaced text in the theme's font, offset from the base size
    func mono(_ offset: Double = 0, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
        let size = font.size + offset
        return font.family == "system-mono"
            ? .system(size: size, weight: weight, design: .monospaced)
            : .custom(font.family, fixedSize: size).weight(weight)
    }

    // the letter-spaced labels on the chrome (indicator, dom, time, size): set in caps with .tracking
    func caps(_ offset: Double = -3, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
        .system(size: font.size + offset, weight: weight)
    }

    // running text, the (?) cards: numbers stay mono, sentences read better proportional
    func prose(_ offset: Double = 0, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
        .system(size: font.size + offset, weight: weight)
    }
}

struct ThemeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

extension Theme {
    // lays the file over the default theme, so a theme only lists what it changes
    static func load(_ data: Data) throws -> Theme {
        guard let custom = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThemeError("a theme has to be a json object")
        }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(standard)) as! [String: Any]
        let merged = try merge(custom, into: base, path: "")

        let theme: Theme
        do {
            theme = try JSONDecoder().decode(Theme.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch let error as DecodingError {
            // a merged theme has every key, so only wrong types and bad colors land here
            switch error {
            case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
                throw ThemeError("\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)")
            @unknown default:
                throw error
            }
        }

        if theme.font.family != "system-mono" && NSFont(name: theme.font.family, size: 12) == nil {
            throw ThemeError("font.family: \"\(theme.font.family)\" isn't installed on this mac")
        }
        let ranges: [(String, Double, ClosedRange<Double>)] = [
            ("font.size", theme.font.size, 8...24),
            ("layout.domWidth", theme.layout.domWidth, 240...1200),
            ("layout.domRowHeight", theme.layout.domRowHeight, 14...40),
            ("layout.candleWidth", theme.layout.candleWidth, 0.1...1)
        ]
        for (key, value, range) in ranges where !range.contains(value) {
            throw ThemeError("\(key): \(value) is outside \(range.lowerBound)-\(range.upperBound)")
        }
        return theme
    }

    private static func merge(_ custom: [String: Any], into base: [String: Any], path: String) throws -> [String: Any] {
        var result = base
        for (key, value) in custom {
            let keyPath = path.isEmpty ? key : "\(path).\(key)"
            guard let current = base[key] else {
                throw ThemeError("\(keyPath) is not a theme setting")
            }
            if let section = current as? [String: Any] {
                guard let customSection = value as? [String: Any] else { throw ThemeError("\(keyPath) has to be an object") }
                result[key] = try merge(customSection, into: section, path: keyPath)
            } else {
                result[key] = value
            }
        }
        return result
    }

    func export() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(self)
    }
}

// the active theme: one of the built-ins by name, or the imported file.
// an imported file is copied into application support so it survives the original moving
@MainActor @Observable
final class ThemeStore {
    static let custom = "custom"

    private(set) var theme = Theme.standard
    // a built-in theme's name, or ThemeStore.custom
    private(set) var choice = Theme.standard.name
    // the imported theme, nil when none was imported
    private(set) var imported: Theme?
    private(set) var error: String?
    // where the imported theme came from, reload reads it again after edits
    private(set) var source: URL?

    private static let folder = URL.applicationSupportDirectory.appending(path: "Counterparty")
    private static let saved = folder.appending(path: "theme.json")
    private static let choiceKey = "themeChoice"
    private static let sourceKey = "themeSource"

    // built-ins first, then the imported one
    var choices: [String] {
        Theme.builtins.map(\.name) + (imported == nil ? [] : [Self.custom])
    }

    func title(of choice: String) -> String {
        guard choice == Self.custom, let imported else { return choice }
        return "\(imported.name) (imported)"
    }

    init() {
        source = UserDefaults.standard.url(forKey: Self.sourceKey)
        if FileManager.default.fileExists(atPath: Self.saved.path) {
            do {
                imported = try Theme.load(Data(contentsOf: Self.saved))
            } catch {
                self.error = "Imported theme couldn't be loaded. \(error.localizedDescription)"
            }
        }
        // before built-ins existed, an imported file was always the active theme
        UserDefaults.standard.register(defaults: [Self.choiceKey: imported == nil ? Theme.standard.name : Self.custom])
        let saved = UserDefaults.standard.string(forKey: Self.choiceKey)!
        // the default used to be called "Default" and atelier was its own built-in, both are atelier now
        let renamed = saved == "Default" ? Theme.standard.name : saved
        if choices.contains(renamed) {
            choose(renamed)
        } else if error == nil {
            error = "Theme \"\(saved)\" no longer exists, using the default."
        }
    }

    func choose(_ choice: String) {
        if choice == Self.custom {
            guard let imported else { return }
            theme = imported
        } else {
            theme = Theme.builtins.first { $0.name == choice }!
        }
        self.choice = choice
        UserDefaults.standard.set(choice, forKey: Self.choiceKey)
    }

    func importTheme(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loaded = try Theme.load(data)
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try data.write(to: Self.saved, options: .atomic)
            imported = loaded
            source = url
            UserDefaults.standard.set(url, forKey: Self.sourceKey)
            error = nil
            choose(Self.custom)
        } catch {
            self.error = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reload() {
        guard let source else { return }
        importTheme(from: source)
    }

    // deletes the imported theme, and goes back to the default if it was in use
    func removeImported() {
        do {
            if FileManager.default.fileExists(atPath: Self.saved.path) {
                try FileManager.default.removeItem(at: Self.saved)
            }
        } catch {
            self.error = "Couldn't remove the imported theme: \(error.localizedDescription)"
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.sourceKey)
        imported = nil
        source = nil
        error = nil
        if choice == Self.custom { choose(Theme.standard.name) }
    }
}
