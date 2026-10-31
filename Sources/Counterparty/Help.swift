import SwiftUI

// what a card says: what the thing is, and an example of reading it, a good case and a bad one
struct Hint: Equatable, ExpressibleByStringInterpolation {
    let text: String
    let example: String?

    init(_ text: String, example: String? = nil) {
        self.text = text
        self.example = example
    }

    init(stringLiteral value: String) {
        self.init(value)
    }
}

// the (?) mode: while it's on, hovering anything shows what it means in a card next to the cursor.
// clicks are caught by the explained areas, so nothing changes by accident while reading
@MainActor @Observable
final class HelpMode {
    static let space = "window"

    var on = false {
        didSet { if !on { hint = nil } }
    }
    private(set) var hint: Hint?
    // cursor in the window, where the card is drawn
    private(set) var at = CGPoint.zero
    @ObservationIgnored private var owner: UUID?

    func show(_ hint: Hint?, at point: CGPoint, owner: UUID) {
        self.owner = owner
        if self.hint != hint { self.hint = hint }
        at = point
    }

    // moving from one area into the next can end the first after the second began
    func hide(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        hint = nil
    }
}

extension View {
    func explain(_ hint: Hint) -> some View {
        modifier(Explain(hint: { _, _ in hint }))
    }

    // for canvases: the card depends on where in the view the cursor is, nil explains nothing there
    func explain(_ hint: @escaping (CGPoint, CGSize) -> Hint?) -> some View {
        modifier(Explain(hint: hint))
    }
}

private struct Explain: ViewModifier {
    @Environment(HelpMode.self) private var help
    @State private var id = UUID()
    let hint: (CGPoint, CGSize) -> Hint?

    func body(content: Content) -> some View {
        content.overlay {
            if help.on {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(.rect)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let origin = geometry.frame(in: .named(HelpMode.space)).origin
                                help.show(hint(point, geometry.size), at: CGPoint(x: origin.x + point.x, y: origin.y + point.y), owner: id)
                            case .ended:
                                help.hide(owner: id)
                            }
                        }
                        .onTapGesture {}
                }
            }
        }
    }
}

// the card, its own view so a moving cursor only redraws the card
struct HelpCard: View {
    let help: HelpMode
    let theme: Theme

    var body: some View {
        GeometryReader { geometry in
            if let hint = help.hint {
                let width = min(340, geometry.size.width - 16)
                let x = min(help.at.x + 14, geometry.size.width - width - 8)
                let card = VStack(alignment: .leading, spacing: 8) {
                    Text(hint.text).foregroundStyle(theme.colors.text.color)
                    if let example = hint.example {
                        theme.colors.border.color.frame(height: 1)
                        Text("Example").fontWeight(.semibold).foregroundStyle(theme.colors.accent.color)
                        Text(example).foregroundStyle(theme.colors.text.color.opacity(0.8))
                    }
                }
                .font(theme.mono(-1))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(width: width, alignment: .leading)
                .background(theme.colors.panel.color, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.colors.accent.color.opacity(0.6)))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                // below the cursor in the top half of the window, above it in the bottom half
                if help.at.y < geometry.size.height / 2 {
                    card.offset(x: x, y: help.at.y + 20)
                } else {
                    card.frame(height: max(0, help.at.y - 12), alignment: .bottom).offset(x: x)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
