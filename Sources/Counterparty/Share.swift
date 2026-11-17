import AppKit
import CounterpartyKit
import SwiftUI

// how the shared picture is laid out
enum ShareStyle: String, CaseIterable {
    // the chart fills the picture, the note is a small card pinned to its bar
    case pinned = "Pinned"
    // the note's words set large, the candles a quiet strip under them
    case quote = "Quote"
    // a post: who, the words, the chart attached like a photo
    case post = "Post"
}

// the picture a note is shared as
struct ShareCard: View {
    let note: Note
    let journal: Journal
    let theme: Theme
    let style: ShareStyle
    // off leaves the chart out, the picture is just the note
    let chart: Bool

    var body: some View {
        Group {
            switch style {
            case .pinned: pinned
            case .quote: quote
            case .post: post
            }
        }
        .foregroundStyle(theme.colors.text.color)
        .frame(width: 640)
        .background(theme.colors.background.color)
    }

    // where on the chart and how it went: BTC · 5m · 65290.5 · LONG → 65410.0 +0.18%
    private var target: some View {
        HStack(spacing: 7) {
            Text(note.coin).fontWeight(.semibold).foregroundStyle(theme.colors.accent.color)
            // the bars' own timeframe, which the picture picks to fit the time since the note
            Text(timeframeLabel(note.barTimeframe)).foregroundStyle(theme.colors.muted.color)
            Text(price(note.price, decimals: note.decimals))
            Outcome(note: note, theme: theme)
        }
        .font(theme.mono(-1))
    }

    private var brand: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(theme.colors.accent.color).frame(width: 6, height: 6)
            CapsLabel("Counterparty", theme: theme)
        }
    }

    // the small card: avatar, name and the words, the way it reads on the chart in the app
    private var bubble: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(journal: journal, theme: theme, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(journal.name).font(theme.prose(0, weight: .semibold))
                    Text(barTime(note.time, timeframe: note.timeframe)).font(theme.mono(-3)).foregroundStyle(theme.colors.muted.color)
                }
                Text(note.text)
                    .font(theme.prose())
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(theme.colors.panel.color, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.colors.accent.color.opacity(0.45)))
    }

    @ViewBuilder
    private var pinned: some View {
        if chart {
            // the card sits in its own band over the chart, on a stem down to its bar, so no candle is covered
            let size = CGSize(width: 640, height: 400)
            let mark = NoteLayout(note: note, theme: theme, size: size).mark
            let cardWidth = 300.0
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    target
                    Spacer()
                    brand
                }
                .padding(16)
                bubble
                    .frame(width: cardWidth)
                    .padding(.leading, mark.map { min(max(16, $0.x - 26), size.width - cardWidth - 16) } ?? 16)
                NoteChart(note: note, journal: journal, theme: theme, stem: true).frame(height: size.height)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                target
                bubble
                brand
            }
            .padding(24)
        }
    }

    private var quote: some View {
        // candles and the note's level only, nothing to read numbers off
        var bare = theme
        bare.show.priceAxis = false
        bare.show.timeAxis = false
        bare.show.grid = false
        bare.show.volume = false
        bare.show.delta = false
        bare.show.liquidations = false
        bare.show.cvd = false
        bare.show.lastPriceLine = false
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    target
                    Spacer()
                    CapsLabel(barTime(note.time, timeframe: note.timeframe), theme: theme)
                }
                Text(note.text)
                    .font(theme.prose(11, weight: .medium))
                    .lineSpacing(8)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Avatar(journal: journal, theme: theme, size: 30)
                    Text(journal.name).font(theme.prose(1, weight: .semibold))
                    Spacer()
                    brand
                }
            }
            .padding(36)
            if chart {
                NoteChart(note: note, journal: journal, theme: bare, stem: false)
                    .frame(height: 170)
                    .padding(.bottom, -24)
            }
        }
    }

    private var post: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Avatar(journal: journal, theme: theme, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(journal.name).font(theme.prose(2, weight: .semibold))
                    target
                }
                Spacer()
                CapsLabel(barTime(note.time, timeframe: note.timeframe), theme: theme)
            }
            Text(note.text)
                .font(theme.prose(4))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            if chart {
                NoteChart(note: note, journal: journal, theme: theme, stem: false)
                    .frame(height: 280)
                    .background(theme.colors.background.color)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.colors.border.color))
            }
            brand
        }
        .padding(24)
        .background(theme.colors.panel.color, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.colors.border.color))
        .padding(28)
    }
}

// where a note's bars and its mark land in a chart of a given size
private struct NoteLayout {
    let painter: ChartPainter
    let frame: ChartFrame
    let range: ClosedRange<Double>
    // nil when the bar the note was taken on isn't among its bars
    let mark: CGPoint?

    init(note: Note, theme: Theme, size: CGSize) {
        painter = ChartPainter(theme: theme, decimals: note.decimals, timeframe: note.barTimeframe)
        let width = size.width - painter.axisWidth
        // prices fit the bars and the note, which can sit above or below every candle
        let candles = note.bars.compactMap(\.candle)
        let low = (candles.map(\.low) + [note.price]).min()!
        let high = (candles.map(\.high) + [note.price]).max()!
        let span = max(high - low, (low + high) / 2 * 0.002) * 1.16
        let range = ((low + high - span) / 2)...((low + high + span) / 2)
        // the bars fill the width, the few there are drawn big
        let viewport = Viewport(spacing: min(40, width / Double(note.bars.count + 3)), autoScale: false, range: range)
        let frame = ChartFrame(points: note.bars, width: width, height: size.height - painter.axisHeight, viewport: viewport)
        self.frame = frame
        self.range = range
        mark = note.bars.firstIndex { $0.time == note.barTime }.map { CGPoint(x: frame.x($0), y: frame.y(note.price, in: range)) }
    }
}

// the note's own bars drawn by the chart's painter, with the avatar where the note was taken.
// the stem is a line from the top edge down to the avatar, for a card sitting above the chart
private struct NoteChart: View {
    let note: Note
    let journal: Journal
    let theme: Theme
    let stem: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = NoteLayout(note: note, theme: theme, size: geometry.size)
            Canvas { context, _ in
                // the stretch from the note to the newest close, shaded in the colour of how it went,
                // under the candles so they read through it
                if let mark = layout.mark, let last = note.lastClose, let result = note.result {
                    let end = layout.frame.x(note.bars.count - 1)
                    let lastY = layout.frame.y(last, in: layout.range)
                    let band = CGRect(x: mark.x, y: min(mark.y, lastY), width: max(0, end - mark.x), height: abs(lastY - mark.y))
                    context.fill(Path(band), with: .color((result >= 0 ? theme.colors.buy : theme.colors.sell).color.opacity(0.16)))
                }
                layout.painter.draw(note.bars, layout.frame, crosshair: nil, level: note.price, in: &context)
            }
            if let mark = layout.mark {
                if stem {
                    Path { path in
                        path.move(to: CGPoint(x: mark.x, y: 0))
                        path.addLine(to: mark)
                    }
                    .stroke(theme.colors.accent.color.opacity(0.45), lineWidth: 1)
                }
                Avatar(journal: journal, theme: theme, size: 22)
                    .overlay(Circle().strokeBorder(theme.colors.accent.color, lineWidth: 1.5))
                    .position(mark)
            }
        }
    }
}

// the share sheet: the picture as it will go out, how it's laid out, the theme it's drawn in, and where it goes
struct ShareView: View {
    // the coin's markets, to read the note's bars again
    let markets: [String]
    let journal: Journal
    let themes: ThemeStore

    @State private var note: Note
    // the bars the picture is cut from, read again for the sheet. nil until they're in, the note's own are shown then
    @State private var model: IndicatorModel?
    // which of them the picture shows: its first bar and how many, fractional so small trackpad moves add up.
    // swiping, dragging and pinching the preview change them like the chart's own, and the picture and the
    // stored note follow
    @State private var lower = 0.0
    @State private var count = 0.0
    // where a drag on the preview started
    @State private var dragFrom: Double?

    @State private var choice: String
    @State private var status: String?
    // the bars' timeframe picked in the sheet, nil picks one that fits the time since the note
    @State private var span: Int?
    @AppStorage("shareStyle") private var style = ShareStyle.pinned
    @AppStorage("shareChart") private var chart = true
    @Environment(\.dismiss) private var dismiss

    init(note: Note, markets: [String], journal: Journal, themes: ThemeStore) {
        _note = State(initialValue: note)
        self.markets = markets
        self.journal = journal
        self.themes = themes
        // starts in the theme the app is in
        _choice = State(initialValue: themes.choice)
    }

    var body: some View {
        // the sheet wears the app's theme, the picture the one picked here
        let theme = themes.theme
        let image = render()
        HStack(spacing: 0) {
            Group {
                if let image {
                    Image(decorative: image, scale: 2).resizable().scaledToFit()
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                } else {
                    Text("The picture couldn't be drawn.").foregroundStyle(theme.colors.statusDown.color)
                }
            }
            .frame(width: 480, height: 500)
            // the chart's own input: two-finger swipe sideways or drag moves along the bars, swipe up and down or
            // pinch zooms around the note, double-click fits again. a nsview, swiftui doesn't see swipes on macos
            .overlay {
                if chart && model != nil {
                    ChartInputView(axisX: .infinity, axisY: .infinity, menu: { _ in nil }) { handle($0) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if chart && model != nil {
                    HStack(spacing: 4) {
                        zoomButton("minus", theme) { zoom(by: 0.7) }
                        zoomButton("plus", theme) { zoom(by: 1.4) }
                    }
                    .padding(6)
                    .help("Swipe, drag or pinch the picture like the chart, double-click to fit")
                }
            }
            .padding(28)
            .background(theme.colors.background.color)
            theme.colors.border.color.frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                CapsLabel("Style", theme: theme).padding(.bottom, 4)
                RuleSegments(items: ShareStyle.allCases, selection: $style, theme: theme) { style, _ in
                    Text(style.rawValue)
                }
                .padding(.leading, -8)
                Toggle("Chart", isOn: $chart).toggleStyle(LampToggleStyle(theme: theme)).padding(.top, 8)
                HStack {
                    CapsLabel("Bars", theme: theme)
                    Spacer()
                    Picker("Bars", selection: $span) {
                        Text("Auto").tag(Int?.none)
                        ForEach(timeframes, id: \.self) { Text(timeframeLabel($0)).tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!chart)
                }
                .padding(.top, 12)
                // the trade the note is about, set here too for notes written before there was a choice
                CapsLabel("Trade", theme: theme).padding(.top, 16).padding(.bottom, 4)
                RuleSegments(items: [nil, Note.Side.long, .short], selection: Binding(get: { note.side }, set: {
                    note.side = $0
                    journal.save(note)
                }), theme: theme) { side, _ in
                    Text(side.map { $0 == .long ? "Long" : "Short" } ?? "None")
                }
                .padding(.leading, -8)
                CapsLabel("Theme", theme: theme).padding(.top, 16).padding(.bottom, 6)
                ForEach(themes.choices, id: \.self) { name in
                    themeRow(name, theme)
                }
                Spacer(minLength: 12)
                if let status {
                    Text(status)
                        .font(theme.mono(-2))
                        .foregroundStyle(theme.colors.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                }
                VStack(spacing: 6) {
                    target("Copy Image", theme) { copy($0) }
                    target("WhatsApp", theme) { send($0, to: "whatsapp://send") }
                    target("X", theme) { send($0, to: "https://x.com/intent/post") }
                    target("Save PNG…", theme) { save($0) }
                }
                .disabled(image == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 12)
            }
            .padding(20)
            .frame(width: 230)
        }
        .frame(height: 556)
        .font(theme.mono(-1))
        .foregroundStyle(theme.colors.text.color)
        .background(theme.colors.panel.color)
        .tint(theme.colors.accent.color)
        .preferredColorScheme(theme.appearance == .light ? .light : .dark)
        .task(id: span) { await refresh() }
    }

    // reads the chart again for the picture. unless a timeframe is picked, the bars are as long as it takes to
    // fit the time since the note in about 30 of them, so a note from ten minutes ago gets 15s bars and one from
    // last week gets hours. the bars end now, or 300 bars after the note when that's earlier, so even 5s bars
    // reach an old note; moving to the left edge loads the bars before, like the chart
    private func refresh() async {
        model = nil
        let now = Int(Date.now.timeIntervalSince1970)
        let elapsed = max(1, now - note.time)
        let span = span ?? timeframes.min { abs(Double(elapsed) / Double($0) - 30) < abs(Double(elapsed) / Double($1) - 30) }!
        let loaded = IndicatorModel()
        let end = min(now, barStart(note.time, timeframe: span) + 300 * span)
        await loaded.load(timeframe: span, markets: markets, until: Date(timeIntervalSince1970: Double(end)))
        if Task.isCancelled { return }
        if let error = loaded.error {
            status = "Couldn't read the chart again, this is how it stood. \(error)"
            return
        }
        guard loaded.points.contains(where: { $0.time == barStart(note.time, timeframe: span) }) else {
            status = "aggr has no \(timeframeLabel(span)) bars for this note, pick another timeframe."
            return
        }
        status = nil
        note.span = span
        model = loaded
        fit()
        save()
    }

    private var bars: [Point] { model?.points ?? [] }

    // about half as many bars before the note as after it, at most 60 after: enough to see what led there,
    // few enough that the candles stay big and the picture is mostly what came next
    private func fit() {
        guard let index = bars.firstIndex(where: { $0.time == note.barTime }) else { return }
        let after = min(60, bars.count - 1 - index)
        let before = min(25, max(12, after / 2))
        lower = Double(index - before)
        count = Double(before + after + 1)
        apply()
    }

    // fewer bars when the factor is over 1, more when it's under, with the note's bar kept where it is on screen
    // (or the middle, when it's out of view)
    private func zoom(by factor: Double) {
        guard !bars.isEmpty else { return }
        let index = bars.firstIndex(where: { $0.time == note.barTime }).map(Double.init)
        let anchor = index.flatMap { $0 >= lower && $0 < lower + count ? $0 : nil } ?? lower + count / 2
        let share = (anchor - lower) / count
        count = min(Double(bars.count), max(8, count / factor))
        lower = anchor - share * count
        apply()
    }

    private func handle(_ input: ChartInput) {
        // the chart is about 440 points wide in the preview
        let perPoint = count / 440
        switch input {
        case .scroll(let dx, let dy, let precise, _):
            if precise {
                // trackpad: the bigger axis wins so a diagonal swipe doesn't do both
                if abs(dx) > abs(dy) {
                    lower -= dx * perPoint
                    apply()
                } else {
                    zoom(by: exp(dy * 0.01))
                }
            } else if dx != 0 {
                lower -= dx * 2
                apply()
            } else {
                zoom(by: exp(dy * 0.1))
            }
        case .pinch(let magnification, _):
            zoom(by: 1 + magnification)
        case .press(_, let clicks):
            if clicks == 2 { fit() }
            dragFrom = lower
        case .drag(let moved):
            guard let dragFrom else { return }
            lower = dragFrom - moved.width * perPoint
            apply()
        case .release:
            dragFrom = nil
            save()
        case .reset:
            fit()
        case .hover:
            break
        }
    }

    // keeps the view on the bars and puts its bars in the note. near the left edge the bars before are
    // loaded, and the view stays on the same bars once they're in front
    private func apply() {
        guard let model, !bars.isEmpty else { return }
        count = min(Double(bars.count), max(8, count))
        lower = min(max(0, lower), Double(bars.count) - count)
        let first = Int(lower.rounded())
        let shown = first..<min(bars.count, first + Int(count.rounded()))
        let picked = Array(bars[shown])
        if picked.first?.time != note.bars.first?.time || picked.count != note.bars.count { note.bars = picked }
        if lower < 20 && !model.loadingOlder {
            Task {
                let added = await model.loadOlder()
                lower += Double(added)
                if added > 0 { apply() }
            }
        }
    }

    // the picture keeps the bars it was last shown with
    private func save() {
        journal.save(note)
    }

    private func zoomButton(_ symbol: String, _ theme: Theme, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            save()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(theme.colors.panel.color.opacity(0.9), in: .rect(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.colors.border.color))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.colors.text.color)
    }

    // a theme to draw the picture in: its background, candle and accent as three dots, then its name
    private func themeRow(_ name: String, _ theme: Theme) -> some View {
        let colors = themes.theme(of: name).colors
        let picked = name == choice
        return Button {
            choice = name
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: -3) {
                    ForEach(Array([colors.background, colors.candleUp, colors.accent].enumerated()), id: \.offset) { _, color in
                        Circle().fill(color.color).frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(theme.colors.border.color))
                    }
                }
                Text(themes.title(of: name)).lineLimit(1)
                Spacer()
            }
            .foregroundStyle((picked ? theme.colors.text : theme.colors.muted).color)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .overlay(alignment: .leading) {
                if picked { theme.colors.accent.color.frame(width: 1.5) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // one place the picture can go, drawn again in the picked theme when it's pressed
    private func target(_ title: String, _ theme: Theme, _ action: @escaping (CGImage) -> Void) -> some View {
        Button {
            if let image = render() { action(image) }
        } label: {
            Text(title.uppercased())
                .font(theme.caps())
                .tracking(1.2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.colors.border.color))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func render() -> CGImage? {
        let renderer = ImageRenderer(content: ShareCard(note: note, journal: journal, theme: themes.theme(of: choice), style: style, chart: chart))
        renderer.scale = 2
        return renderer.cgImage
    }

    private func copy(_ image: CGImage) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let board = NSPasteboard.general
        board.declareTypes([.png, .tiff], owner: nil)
        board.setData(bitmap.representation(using: .png, properties: [:]), forType: .png)
        board.setData(bitmap.tiffRepresentation, forType: .tiff)
        status = "Picture copied."
    }

    // neither whatsapp nor x takes a picture through a link, so the picture goes on the clipboard
    // and the app opens with the note's words filled in
    private func send(_ image: CGImage, to link: String) {
        copy(image)
        var url = URLComponents(string: link)!
        let words = "\(note.text)\n\n$\(note.coin) \(price(note.price, decimals: note.decimals)) · \(timeframeLabel(note.timeframe))"
        url.queryItems = [URLQueryItem(name: "text", value: words)]
        status = NSWorkspace.shared.open(url.url!)
            ? "Picture copied. Paste it into the message with ⌘V."
            : "Picture copied, but nothing on this mac opens \(link)."
    }

    private func save(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(note.coin) note.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
