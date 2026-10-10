import SwiftUI

struct WatchSessionView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject private var bridge: WatchBridge
    @State private var showingDetails = false

    init(model: WatchSessionModel) {
        self.model = model
        bridge = model.bridge
    }

    var body: some View {
        TabView {
        ScrollView {
            VStack(spacing: 12) {
                GelCompanion(active: model.running).frame(height: 95)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(model.heartRate.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("bpm").font(.caption).foregroundStyle(.secondary)
                }
                if model.running, let start = model.startedAt {
                    Text(start, style: .timer).font(.caption.monospacedDigit())
                }
                if !model.message.isEmpty { Text(model.message).font(.caption2).multilineTextAlignment(.center) }
                Button {
                    if model.running { model.stop() }
                    else { Task { await model.start() } }
                } label: {
                    Label(model.running ? "終了" : "開始", systemImage: model.running ? "stop.fill" : "play.fill")
                }.buttonStyle(.borderedProminent).tint(model.running ? .orange : GelPalette.mint).disabled(model.busy)
                    .accessibilityLabel(model.running ? "心拍計測を終了" : "心拍計測を開始")
                Label(bridge.reachable ? "接続中" : "iPhone待機", systemImage: "iphone").font(.caption2).foregroundStyle(.secondary)
                Button { showingDetails.toggle() } label: {
                    HStack {
                        Text("詳細")
                        Spacer()
                        Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
                    }
                }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityValue(showingDetails ? "展開" : "折りたたみ")
                if showingDetails { Text(bridge.status).font(.caption2).foregroundStyle(.secondary) }
            }.padding(.horizontal, 6)
        }
        TimelineView(.periodic(from: .now, by: 2)) { context in
            ScrollView {
                VStack(spacing: 10) {
                    Text("指令プレビュー").font(.caption.bold())
                    if let state = bridge.companion, (0...20).contains(context.date.timeIntervalSince(state.date)) {
                        GelCompanion(state: state.haptic, active: state.armed).frame(height: 100)
                        Text(state.armed ? "出力中" : "出力停止").font(.caption2).foregroundStyle(GelPalette.mint)
                        Text("温度 \(state.haptic.temperature, specifier: "%.2f")\n硬さ \(state.haptic.stiffness, specifier: "%.2f")")
                            .font(.system(.title3, design: .rounded).monospacedDigit())
                    } else {
                        GelCompanion().frame(height: 100)
                        Text("iPhoneでGelLinkを開いてください").font(.caption).multilineTextAlignment(.center)
                    }
                }.padding(.horizontal, 6)
            }
        }
        }.tabViewStyle(.page)
    }
}
