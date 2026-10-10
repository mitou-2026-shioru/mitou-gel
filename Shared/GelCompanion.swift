import SwiftUI

enum GelPalette {
    static let ink = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let lavender = Color(red: 0.78, green: 0.75, blue: 0.96)
    static let mint = Color(red: 0.48, green: 0.76, blue: 0.64)
    static let coral = Color(red: 0.91, green: 0.44, blue: 0.35)
    static let blue = Color(red: 0.38, green: 0.53, blue: 0.86)
}

struct GelCompanion: View {
    var state: HapticState = .neutral
    var active = false
    var listening = false
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !animated || (!active && !listening))) { context in
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let time = context.date.timeIntervalSince1970
                let breathing = reduceMotion || !animated ? 0 : sin(time * 2) * 0.018
                let blinking = !reduceMotion && animated && time.truncatingRemainder(dividingBy: 4.8) < 0.16
                ZStack {
                    Ellipse().fill(GelPalette.ink.opacity(0.06))
                        .frame(width: size * 0.64, height: size * 0.08).offset(y: size * 0.36)
                    if listening {
                        Circle().stroke(GelPalette.lavender.opacity(0.45), lineWidth: 2)
                            .frame(width: size * 0.98).scaleEffect(1 + breathing * 3)
                    }
                    GelBody(stiffness: state.stiffness)
                        .fill(LinearGradient(colors: [GelPalette.lavender, temperatureColor],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(GelBody(stiffness: state.stiffness).stroke(.white.opacity(0.7), lineWidth: 2))
                        .frame(width: size * (0.85 - state.stiffness * 0.08), height: size * (0.65 + state.stiffness * 0.06))
                        .rotationEffect(.degrees(listening && !reduceMotion && animated ? sin(time) * 3 : -3))
                        .scaleEffect(1 + breathing)
                    HStack(spacing: size * 0.22) {
                        Capsule().frame(width: size * 0.055, height: size * (blinking ? 0.018 : 0.095))
                        Capsule().frame(width: size * 0.055, height: size * (blinking ? 0.018 : 0.095))
                    }.foregroundStyle(GelPalette.ink)
                    HStack(spacing: size * 0.36) {
                        Ellipse().frame(width: size * 0.09, height: size * 0.045)
                        Ellipse().frame(width: size * 0.09, height: size * 0.045)
                    }.foregroundStyle(GelPalette.coral.opacity(0.35)).offset(y: size * 0.06)
                    GelSmile().stroke(GelPalette.ink, style: StrokeStyle(lineWidth: max(2, size * 0.012), lineCap: .round))
                        .frame(width: size * 0.09, height: size * 0.045).offset(y: size * 0.09)
                    Ellipse().fill(.white.opacity(0.45)).frame(width: size * 0.13, height: size * 0.05)
                        .rotationEffect(.degrees(-25)).offset(x: -size * 0.2, y: -size * 0.17)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ゲルの相棒。温度指令\(Int(state.temperature * 100))パーセント、硬さ指令\(Int(state.stiffness * 100))パーセント。\(listening ? "録音中" : active ? "入力中" : "待機中")")
    }

    private var temperatureColor: Color {
        let position = HapticState.unit(state.temperature)
        if position < 0.5 {
            let fraction = position * 2
            return Color(red: 0.58 + fraction * 0.07, green: 0.76 + fraction * 0.08, blue: 0.99 - fraction * 0.23)
        }
        let fraction = (position - 0.5) * 2
        return Color(red: 0.65 + fraction * 0.35, green: 0.84 - fraction * 0.03, blue: 0.76 - fraction * 0.04)
    }
}

private struct GelBody: Shape {
    var stiffness: Double
    var animatableData: Double {
        get { stiffness }
        set { stiffness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let tension = stiffness * 0.08
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.47, y: 0))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.55),
                      control1: CGPoint(x: rect.width * 0.84, y: -rect.height * tension),
                      control2: CGPoint(x: rect.width * 0.99, y: rect.height * 0.17))
        path.addCurve(to: CGPoint(x: rect.width * 0.54, y: rect.height),
                      control1: CGPoint(x: rect.width * 1.04, y: rect.height * 0.94),
                      control2: CGPoint(x: rect.width * 0.75, y: rect.height * 0.96))
        path.addCurve(to: CGPoint(x: 0, y: rect.height * 0.63),
                      control1: CGPoint(x: rect.width * 0.17, y: rect.height * 1.06),
                      control2: CGPoint(x: -rect.width * 0.02, y: rect.height * 0.94))
        path.addCurve(to: CGPoint(x: rect.width * 0.47, y: 0),
                      control1: CGPoint(x: -rect.width * 0.02, y: rect.height * 0.27),
                      control2: CGPoint(x: rect.width * 0.1, y: rect.height * 0.01))
        path.closeSubpath()
        return path
    }
}

private struct GelSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: 0), control: CGPoint(x: rect.midX, y: rect.height))
        return path
    }
}
