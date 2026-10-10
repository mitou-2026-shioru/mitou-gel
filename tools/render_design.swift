import AppKit
import SwiftUI

private struct DesignBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text("GelLink").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("触れる情報と、ちいさな相棒。").font(.title3)
                Spacer()
                Text("SWIFTUI DESIGN STUDY").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 28) {
                phone(voice: false)
                phone(voice: true)
                VStack(alignment: .leading, spacing: 20) {
                    Text("ON YOUR WRIST").font(.caption.monospaced()).tracking(2)
                    VStack(spacing: 8) {
                        Text("ぷにと、いっしょ。").font(.caption.bold()).foregroundStyle(GelPalette.lavender)
                        GelCompanion(active: false, animated: false).frame(width: 150, height: 110)
                        Text("74 bpm").font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text("▶ 計測を開始").font(.caption.bold()).padding(12)
                            .frame(maxWidth: .infinity).background(GelPalette.mint, in: Capsule()).foregroundStyle(.black)
                    }.padding(20).foregroundStyle(.white).frame(width: 220)
                        .background(.black, in: RoundedRectangle(cornerRadius: 45))
                    Text("温度で色が変わり、\n硬さで形が引き締まる。\n\n点の目、ささやかな呼吸。\n情報を届ける、ゲルの相棒。")
                        .font(.subheadline).lineSpacing(7).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        ForEach(0..<4, id: \.self) { index in
                            Circle().fill([GelPalette.lavender, GelPalette.mint, GelPalette.coral, GelPalette.ink][index])
                                .frame(width: 28, height: 28)
                        }
                    }
                }.frame(width: 260)
            }
            Text("コードからオフスクリーン描画したデザイン検討図。実機・Simulatorのスクリーンショットではありません。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(32).background(GelPalette.paper).foregroundStyle(GelPalette.ink)
    }

    private func phone(voice: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("9:41").font(.caption.bold())
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }.font(.caption2)
            HStack {
                Text(voice ? "ことばの窓" : "GelLink").font(.headline)
                Spacer()
                Image(systemName: voice ? "waveform" : "slider.horizontal.3")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(voice ? "VOICE, TO TOUCH." : "HELLO, GEL.").font(.caption2.monospaced()).tracking(2).foregroundStyle(.secondary)
                Text(voice ? "話すことも、触れること。" : "ちいさな相棒、ぷに。")
                    .font(.system(.title2, design: .rounded).bold())
            }
            GelCompanion(state: HapticState(temperature: voice ? 0.72 : 0.48, stiffness: voice ? 0.12 : 0.48),
                         listening: voice, animated: false).frame(height: 155)
            Text(voice ? "うんうん、聞いているよ。" : "いまの変化を、そっと届けるよ。")
                .font(.system(.headline, design: .rounded)).frame(maxWidth: .infinity)
            if voice {
                Text("■ 聞くのをやめる").font(.subheadline.bold()).padding(14).frame(maxWidth: .infinity)
                    .foregroundStyle(.white).background(GelPalette.ink, in: Capsule())
                VStack(alignment: .leading, spacing: 12) {
                    Text("ことばの手がかり").font(.headline)
                    Text("ありがとう。安心して\nリラックスできた。").font(.subheadline).lineSpacing(4)
                    Text("温かく、やわらかな表現").font(.caption.bold())
                    Text("ありがとう · 安心 · リラックス").font(.caption2).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 24))
                Text("8秒の音声窓 · 日本語 · 端末内処理").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Watch").padding(9).background(.white, in: Capsule())
                    Spacer()
                    Text("模擬入力")
                    Spacer()
                    Text("ことば")
                    Spacer()
                    Text("手動")
                }.font(.caption2).padding(5).background(GelPalette.ink.opacity(0.05), in: Capsule())
                VStack(alignment: .leading, spacing: 10) {
                    Label("心拍", systemImage: "heart.fill").font(.caption).foregroundStyle(GelPalette.coral)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("74").font(.system(size: 42, weight: .semibold, design: .rounded))
                        Text("bpm").font(.caption)
                    }
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 40))
                        for index in 1...60 {
                            path.addLine(to: CGPoint(x: Double(index) * 4.6, y: 30 + sin(Double(index) / 4) * 12))
                        }
                    }.stroke(GelPalette.coral, lineWidth: 2).frame(height: 45)
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 24))
                HStack(spacing: 12) { vector("温度指令", value: "0.48"); vector("硬さ指令", value: "0.48") }
            }
            Spacer(minLength: 0)
            HStack {
                ForEach(["face.smiling", "waveform", "hand.draw", "square.and.pencil", "slider.horizontal.3"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.subheadline).frame(maxWidth: .infinity)
                }
            }.padding(.vertical, 8).foregroundStyle(.secondary)
        }.padding(22).frame(width: 340, height: 730)
            .background(GelPalette.paper, in: RoundedRectangle(cornerRadius: 38))
            .overlay(RoundedRectangle(cornerRadius: 38).stroke(.white, lineWidth: 5))
    }

    private func vector(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 24))
    }
}

@main
struct RenderDesign {
    @MainActor static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let icon = arguments.first == "--icon"
        let content: AnyView
        if icon {
            content = AnyView(GelCompanion(state: HapticState(temperature: 0.62, stiffness: 0.25), animated: false)
                .frame(width: 860, height: 860).frame(width: 1_024, height: 1_024)
                .background(GelPalette.paper))
        } else { content = AnyView(DesignBoard()) }
        let renderer = ImageRenderer(content: content)
        renderer.isOpaque = true
        renderer.scale = icon ? 1 : 2
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let path = icon ? arguments.dropFirst().first ?? "iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
            : arguments.first ?? "docs/design-preview.png"
        try data.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}
