import SwiftUI

// the launch intro, drawn full window from the app icon's own shapes (Assets/AppIcon.svg, 1024 units):
// while the markets load he looks up at an empty sky. when they're in, a moon rises, he draws
// and shoots it, and the moon drops in behind him as the lamp of the logo. the last frame is the logo's scene
struct IntroView: View {
    let ready: Bool
    let theme: Theme
    let onFinish: () -> Void

    @State private var shown = Date()
    @State private var lookingUp = true
    @State private var moonIn = false
    @State private var moonHome = false
    @State private var armUp = false
    // the arm stays in his coat while he waits, it only shows once he draws
    @State private var armOut = false
    @State private var armGone = false
    @State private var recoil = false
    @State private var flash = 0.0
    @State private var glow = 0.0
    @State private var tracerHead = 0.0
    @State private var tracerTail = 0.0
    @State private var rim = 1.0
    @State private var caption = true
    @State private var leaving = false

    var body: some View {
        GeometryReader { window in
            // a small figure in the middle of the window, no tile around him. the drawing's own middle
            // (the lamp to the coat hem, x 573 y 568) sits on the window's middle
            let scale = window.size.height / 4000
            ZStack {
                moon
                figure
                hat
                    .rotationEffect(.degrees(lookingUp ? -28 : 0), anchor: Self.neck)
            }
            .frame(width: 1024, height: 1024)
            // the coat fades out at the hem instead of stopping on a straight cut
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 0.94)], startPoint: .top, endPoint: .bottom)
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: window.size.width / 2 - 573 * scale, y: window.size.height / 2 - 568 * scale)

            Text("reading every exchange's markets")
                .font(theme.mono(-1))
                .foregroundStyle(theme.colors.muted.color)
                .phaseAnimator([1.0, 0.4]) { text, opacity in text.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.7) }
                .opacity(caption ? 1 : 0)
                .fixedSize()
                .position(x: window.size.width / 2, y: window.size.height / 2 + 392 * scale + 28)
        }
        .scaleEffect(leaving ? 0.96 : 1)
        .blur(radius: leaving ? 6 : 0)
        .opacity(leaving ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(theme.colors.background.color.opacity(leaving ? 0 : 1))
        .task(id: ready) { await play() }
    }

    // MARK: the shapes, in the icon's coordinates

    private static let ink = Color(hex: 0x0E0D0C)
    private static let bone = Color(hex: 0xEAE4D9)
    private static let brass = Color(hex: 0xC2A878)
    // where the head turns on the neck, and where the arm turns at the shoulder
    private static let neck = UnitPoint(x: 530 / 1024, y: 600 / 1024)
    private static let shoulder = CGPoint(x: 612, y: 668)
    // the moon in the sky before it's shot, and the lamp's middle where it ends up
    private static let sky = CGPoint(x: 868, y: 300)
    private static let lamp = CGPoint(x: 566, y: 457)
    private static let skyScale = 0.16
    private static let arm = 250.0
    // the arm points straight at the moon when it's up
    private static let aim = atan2(sky.y - shoulder.y, sky.x - shoulder.x) * 180 / .pi

    private var moon: some View {
        let lamp = SVG("M568 177 C723 178 846 299 845 452 C844 608 718 737 563 737 C409 736 286 612 287 459 C288 303 413 176 568 177 Z")
        let anchor = UnitPoint(x: Self.lamp.x / 1024, y: Self.lamp.y / 1024)
        return ZStack {
            lamp.fill(LinearGradient(colors: [Color(hex: 0xEDE6D8), Self.bone.opacity(0.86)], startPoint: UnitPoint(x: 0.74, y: 0.2), endPoint: UnitPoint(x: 0.37, y: 0.7)))
            // the hit: a white flare on the moon that fades
            lamp.fill(.white).blur(radius: 30).opacity(glow)
        }
        .scaleEffect(moonHome ? 1 : moonIn ? Self.skyScale : 0.04, anchor: anchor)
        .offset(moonHome ? .zero : CGSize(width: Self.sky.x - Self.lamp.x, height: Self.sky.y - Self.lamp.y))
        .blur(radius: moonIn ? 0 : 12)
        .opacity(moonIn ? 1 : 0)
    }

    private var figure: some View {
        let silhouette = SVG("M392 404 C380 436 384 474 404 500 L430 538 L384 504 C378 534 372 566 362 598 C332 610 300 626 276 650 C254 676 244 720 238 790 L234 960 L686 960 L680 820 C676 760 664 714 640 684 L622 650 L600 640 L608 600 L580 592 C574 588 572 582 572 576 C586 572 606 568 618 562 C628 557 632 546 627 537 C624 532 624 528 628 524 L625 520 L630 515 C630 508 628 504 630 500 C638 498 648 496 652 491 C655 487 654 482 650 478 L624 446 C620 441 620 437 622 432 L618 410 L610 404 Z")
        // the body below the neck, the head above it turning on its own
        return ZStack {
            ink(silhouette)
                .mask { Rectangle().frame(height: 1024 - 600).frame(maxHeight: .infinity, alignment: .bottom) }
            SVG("M362 599 C332 611 300 627 276 651 C254 677 244 721 238 791")
                .stroke(LinearGradient(colors: [Self.brass.opacity(0.9), Self.brass.opacity(0)], startPoint: UnitPoint(x: 0.32, y: 0.6), endPoint: UnitPoint(x: 0.23, y: 0.84)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            SVG("M600 641 C590 680 576 730 570 800 C566 850 566 900 568 960").stroke(Color(hex: 0x2A2724), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            SVG("M398 612 C436 640 462 700 472 780 C478 840 480 900 480 960").stroke(Color(hex: 0x2A2724), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            // fills the gap the turning head opens at the neck
            Circle().fill(Self.ink).frame(width: 124, height: 124).position(x: 530, y: 600)
            ink(silhouette)
                .mask { Rectangle().frame(height: 600).frame(maxHeight: .infinity, alignment: .top) }
                .rotationEffect(.degrees(lookingUp ? -28 : 0), anchor: Self.neck)
            gun
        }
    }

    private var hat: some View {
        ZStack {
            ink(SVG("M354 384 C356 342 362 302 374 274 C382 256 398 248 420 249 C446 252 458 264 476 264 C494 264 510 254 530 254 C552 255 566 266 578 290 C590 316 598 348 604 386 Z"))
            SVG("M358 352 C440 358 520 358 599 350 L604 386 C520 393 440 393 354 384 Z").fill(Self.brass)
            ink(SVG("M262 361 C296 371 334 377 372 380 C450 386 540 386 606 382 C652 384 694 395 728 411 C736 415 735 424 726 426 C690 433 640 431 600 428 C520 424 430 420 360 412 C312 405 280 395 264 384 C254 377 252 365 262 361 Z"))
            SVG("M263 362 C290 370 314 375 338 379 L336 383 C312 380 288 375 264 367 Z")
                .fill(LinearGradient(colors: [Self.bone.opacity(0.9), Self.bone.opacity(0)], startPoint: .leading, endPoint: .trailing))
        }
    }

    // the arm, the pistol, its flash and the shot, all drawn pointing right from the shoulder and turned
    private var gun: some View {
        let p = Self.shoulder, l = Self.arm
        let distance = hypot(Self.sky.x - p.x, Self.sky.y - p.y)
        // one outline for sleeve, hand and pistol, so the rim doesn't draw where they overlap
        let arm = Path(roundedRect: CGRect(x: p.x - 26, y: p.y - 27, width: l + 26, height: 54), cornerRadius: 27)
            .union(Path(ellipseIn: CGRect(x: p.x + l - 28, y: p.y - 28, width: 56, height: 56)))
            .union(Path(roundedRect: CGRect(x: p.x + l, y: p.y - 30, width: 84, height: 24), cornerRadius: 6))
            .union(Path(roundedRect: CGRect(x: p.x + l + 2, y: p.y - 12, width: 26, height: 46), cornerRadius: 8))
        let muzzle = CGPoint(x: p.x + l + 92, y: p.y - 18)
        let angle = armUp ? Self.aim + (recoil ? -9 : 0) : 96
        return ZStack {
            ink(arm)
            let shot = Path { path in
                path.move(to: muzzle)
                path.addLine(to: CGPoint(x: p.x + distance, y: p.y - 18))
            }
            shot.trim(from: tracerTail, to: tracerHead)
                .stroke(Self.brass.opacity(0.6), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .blur(radius: 6)
            shot.trim(from: tracerTail, to: tracerHead)
                .stroke(Self.bone, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            Circle()
                .fill(RadialGradient(colors: [.white, Self.brass, Self.brass.opacity(0)], center: .center, startRadius: 0, endRadius: 44))
                .frame(width: 88, height: 88)
                .position(muzzle)
                .scaleEffect(0.4 + flash * 0.8, anchor: UnitPoint(x: muzzle.x / 1024, y: muzzle.y / 1024))
                .opacity(flash)
        }
        .rotationEffect(.degrees(angle), anchor: UnitPoint(x: p.x / 1024, y: p.y / 1024))
        .opacity(armOut && !armGone ? 1 : 0)
    }

    // the figure's ink, with a bone rim while there's no moon behind him to cut him out
    private func ink<S: Shape>(_ shape: S) -> some View {
        shape.fill(Self.ink)
            // 8 units is about 1.3 pt at the intro's size, thinner reads as a smudge
            .overlay { shape.stroke(Self.bone.opacity(0.7 * rim), lineWidth: 8) }
    }

    // MARK: the choreography, niche's springs between short waits

    private func play() async {
        guard ready else { return }
        // the looking-up pose gets at least a moment on screen, even when the markets are quick
        let waited = Date().timeIntervalSince(shown)
        if waited < 0.6 { try? await Task.sleep(for: .seconds(0.6 - waited)) }

        withAnimation(.easeOut(duration: 0.2)) { caption = false }
        withAnimation(.spring(duration: 0.5, bounce: 0.32)) { moonIn = true }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.easeOut(duration: 0.12)) { armOut = true }
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { armUp = true }
        try? await Task.sleep(for: .milliseconds(330))

        // bang: flash, recoil, the tracer runs to the moon
        withAnimation(.easeOut(duration: 0.05)) { flash = 1 }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { recoil = true }
        withAnimation(.easeOut(duration: 0.12)) { tracerHead = 1 }
        withAnimation(.easeIn(duration: 0.14).delay(0.05)) { tracerTail = 1 }
        try? await Task.sleep(for: .milliseconds(70))
        withAnimation(.easeOut(duration: 0.15)) { flash = 0 }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { recoil = false }
        try? await Task.sleep(for: .milliseconds(80))

        // hit: the moon flares and drops in behind him, he lowers the gun and looks ahead
        withAnimation(.easeOut(duration: 0.08)) { glow = 0.9 }
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(.easeOut(duration: 0.4)) { glow = 0 }
        withAnimation(.spring(duration: 0.5, bounce: 0.22)) { moonHome = true }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.95)) { armUp = false }
        withAnimation(.easeOut(duration: 0.25).delay(0.12)) { armGone = true }
        withAnimation(.spring(duration: 0.4, bounce: 0.25).delay(0.06)) { lookingUp = false }
        withAnimation(.easeOut(duration: 0.35)) { rim = 0 }
        try? await Task.sleep(for: .milliseconds(520))

        // that's the logo, a beat to see it, then the app
        withAnimation(.easeOut(duration: 0.25)) { leaving = true }
        try? await Task.sleep(for: .milliseconds(260))
        onFinish()
    }
}

// a path from svg path data, the absolute M, L, C and Z the icon is written with
private struct SVG: Shape {
    let path: Path

    init(_ data: String) {
        var path = Path()
        var numbers: [Double] = []
        var command: Character = "M"
        // a command applies to the numbers that follow it, run it once they're all read
        func flush() {
            switch command {
            case "M": path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "L":
                for i in stride(from: 0, to: numbers.count, by: 2) { path.addLine(to: CGPoint(x: numbers[i], y: numbers[i + 1])) }
            case "C":
                for i in stride(from: 0, to: numbers.count, by: 6) {
                    path.addCurve(
                        to: CGPoint(x: numbers[i + 4], y: numbers[i + 5]),
                        control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                        control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3])
                    )
                }
            case "Z": path.closeSubpath()
            default: preconditionFailure("svg command \(command) isn't supported")
            }
            numbers = []
        }
        // a token is a number, or a command letter with its first number glued on ("M568", "Z")
        for token in data.split(separator: " ") {
            var number = token
            if let letter = token.first, letter.isLetter {
                if command != "M" || !numbers.isEmpty { flush() }
                command = letter
                number = token.dropFirst()
            }
            if !number.isEmpty { numbers.append(Double(number)!) }
        }
        flush()
        self.path = path
    }

    func path(in rect: CGRect) -> Path { path }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
