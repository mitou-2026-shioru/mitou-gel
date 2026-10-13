import Charts
import SwiftUI

struct LabView: View {
    @ObservedObject var lab: LabModel
    @ObservedObject private var device: DeviceClient
    @ObservedObject private var health: HealthReader
    @ObservedObject private var bridge: WatchBridge
    @ObservedObject private var speech: SpeechModel
    @AppStorage("showDiagnostics") private var showDiagnostics = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedSettingsField: SettingsField?
    @State private var participant = "P01"
    @State private var impression = ""
    @State private var warmth = 4
    @State private var hardness = 4
    @State private var studyStates = [HapticState(temperature: 0.25, stiffness: 0),
                                    HapticState(temperature: 0.5, stiffness: 0),
                                    HapticState(temperature: 0.75, stiffness: 0),
                                    HapticState(temperature: 0.25, stiffness: 1),
                                    HapticState(temperature: 0.5, stiffness: 1),
                                    HapticState(temperature: 0.75, stiffness: 1)].shuffled()
    @State private var studyIndex = 0

    private enum SettingsField: Hashable {
        case address, lanPIN
    }

    init(lab: LabModel) {
        self.lab = lab
        device = lab.device
        health = lab.health
        bridge = lab.bridge
        speech = lab.speech
    }

    var body: some View {
        TabView {
            NavigationStack { homeScreen }.tabItem { Label("相棒", systemImage: "face.smiling") }
            NavigationStack { SpeechView(lab: lab) }.tabItem { Label("ことば", systemImage: "waveform") }
            NavigationStack { deviceScreen }.tabItem { Label("ゲル", systemImage: "hand.draw") }
            NavigationStack { studyScreen }.tabItem { Label("記録", systemImage: "square.and.pencil") }
            NavigationStack { settingsScreen }.tabItem { Label("設定", systemImage: "slider.horizontal.3") }
        }
        .foregroundStyle(GelPalette.ink)
        .onChange(of: lab.manualTemperature) { _, _ in lab.updateState() }
        .onChange(of: lab.manualStiffness) { _, _ in lab.updateState() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if lab.armed {
                HStack {
                    Label(device.status?.simulated == true ? "模擬出力" : "出力中",
                          systemImage: "dot.radiowaves.left.and.right").font(.caption.bold())
                    Spacer()
                    Button("停止", role: .destructive) { Task { await lab.stop() } }
                        .buttonStyle(.bordered).font(.caption.bold())
                }.padding(.horizontal, 20).padding(.vertical, 8).background(GelPalette.paper)
            }
        }
    }

    private var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("ぷに").font(.system(.title2, design: .rounded).bold())
                    Spacer()
                    Text(lab.armed ? (device.status?.simulated == true ? "模擬出力" : "出力中") : "プレビュー")
                        .font(.caption.bold()).padding(10).background(.white, in: Capsule())
                }
                VStack(spacing: 2) {
                    GelCompanion(state: lab.haptic, active: lab.inputFresh, listening: speech.recording)
                        .frame(height: 218)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: lab.haptic)
                    Text(companionMessage).font(.system(.title3, design: .rounded).bold()).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.bottom, 16)
                modePicker
                if lab.mode == .conversation {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(lab.expression.usesVoice ? "声を反映中" : "ことば", systemImage: "quote.bubble").font(.headline)
                        if let signal = lab.conversation { Text(signal.text).font(.subheadline).lineLimit(3) }
                    }.gelCard()
                } else if lab.mode != .manual {
                    heartCard
                    if lab.mode == .simulation {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("模擬入力", systemImage: "sparkles").font(.headline)
                            valueSlider("心拍", value: $lab.simulatedHR, range: 45...150, unit: "bpm")
                        }.gelCard()
                    }
                    if showDiagnostics {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("身体の変化 / arousal").font(.headline)
                                Spacer()
                                Text(lab.internalState.arousal, format: .number.precision(.fractionLength(2)))
                                    .font(.title3.monospacedDigit().bold())
                            }
                            ProgressView(value: lab.internalState.arousal).tint(GelPalette.mint)
                        }.gelCard()
                        VStack(alignment: .leading, spacing: 8) {
                            Label(bridge.status, systemImage: "applewatch").font(.subheadline)
                            Text(health.status).font(.caption).foregroundStyle(.secondary)
                            if let date = lab.pipeline.latest?.measuredAt {
                                Text("測定: \(date.formatted(date: .abbreviated, time: .standard))").font(.caption2)
                            }
                            if let value = health.hrvValue, let date = health.hrvDate {
                                Text("HRV \(value, specifier: "%.0f") ms · \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.gelCard()
                    }
                }
                vectorMetrics
                notice
            }.padding(20)
        }.background(GelPalette.paper).navigationTitle("GelLink").navigationBarTitleDisplayMode(.inline)
    }

    private var companionMessage: String {
        if speech.recording { return "聞いているよ" }
        if lab.mode == .conversation { return lab.inputFresh ? "受け取ったよ" : "待機中" }
        if lab.mode == .manual { return "手動プレビュー" }
        return lab.inputFresh ? "入力中" : "待機中"
    }

    private var modePicker: some View {
        Picker("入力を選ぶ", selection: Binding(get: { lab.mode }, set: { value in
            Task { await lab.selectMode(value) }
        })) {
            ForEach(InputMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
        }.pickerStyle(.segmented)
    }

    private var heartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("心拍", systemImage: "heart.fill").foregroundStyle(GelPalette.coral).font(.caption.bold())
                Spacer()
                Text(lab.internalState.fresh ? "更新中" : "待機中").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(lab.pipeline.latest.map { String(format: "%.0f", $0.heartRate) } ?? "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("bpm").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("ベースライン").font(.caption2).foregroundStyle(.secondary)
                    Text("\(lab.internalState.baseline, specifier: "%.0f") bpm").font(.subheadline.monospacedDigit())
                }
            }
            Chart {
                ForEach(lab.pipeline.points) { point in
                    LineMark(x: .value("時刻", point.measuredAt), y: .value("心拍", point.heartRate))
                        .interpolationMethod(.monotone).foregroundStyle(GelPalette.coral)
                }
                RuleMark(y: .value("ベースライン", lab.internalState.baseline))
                    .foregroundStyle(GelPalette.ink.opacity(0.25)).lineStyle(StrokeStyle(dash: [4]))
            }.chartYScale(domain: 40...max(130, (lab.pipeline.points.map(\.heartRate).max() ?? 100) + 10))
                .frame(height: 130)
            if showDiagnostics {
                HStack {
                    Text("変化 \(lab.internalState.delta, specifier: "%+.1f") bpm")
                    Spacer()
                    Text("傾向 \(lab.internalState.trendPerMinute, specifier: "%+.1f") /分")
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("基準を設定") { lab.calibrate() }.buttonStyle(.bordered).font(.caption)
        }.gelCard()
    }

    private var vectorMetrics: some View {
        HStack(spacing: 12) {
            metric("温度指令", value: lab.haptic.temperature, symbol: "thermometer.medium", color: GelPalette.coral)
            metric("硬さ指令", value: lab.haptic.stiffness, symbol: "circle.dotted", color: GelPalette.blue)
        }
    }

    private var deviceScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modePicker
                vectorMetrics
                if lab.connectionKind == .m5Dual {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("目標温度", value: String(format: "%.2f ℃", M5LANProtocol.targetCelsius(lab.haptic.temperature)))
                        LabeledContent("ポンプ設定", value: String(format: "%.2f", M5LANProtocol.appliedPump(lab.haptic.stiffness)))
                        Text("出力開始で温度制御とポンプを開始します。温度0は25℃の目標です。加熱を止めるには「停止」を押してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline).gelCard()
                }
                VStack(alignment: .leading, spacing: 12) {
                    vectorChart
                    if lab.mode != .manual {
                        Picker("触覚の時間窓", selection: Binding(get: { lab.windowSeconds }, set: { value in
                            Task { await lab.changeWindow(value) }
                        })) {
                            ForEach([10, 30, 60], id: \.self) { Text("\($0)秒").tag($0) }
                        }.pickerStyle(.segmented)
                    }
                }.gelCard()
                if lab.mode == .manual {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("手動").font(.headline)
                        valueSlider("温度", value: $lab.manualTemperature, range: 0...1, unit: "")
                        valueSlider("硬さ", value: $lab.manualStiffness, range: 0...1, unit: "")
                        HStack {
                            preset("柔＋温", temperature: 0.75, stiffness: 0)
                            preset("硬＋冷", temperature: 0.25, stiffness: 1)
                            preset("中立", temperature: 0.5, stiffness: 0)
                        }
                    }.gelCard()
                }
                outputControls
                VStack(alignment: .leading, spacing: 12) {
                    Label(deviceSummary, systemImage: deviceAttention ? "exclamationmark.triangle" : device.connected ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.headline).foregroundStyle(deviceAttention ? GelPalette.coral : device.connected ? GelPalette.mint : GelPalette.ink)
                    if let error = device.status?.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(GelPalette.coral)
                    }
                    LabeledContent("実測温度", value: device.status?.actualTemperature.map { String(format: "%.1f °C", $0) } ?? "—")
                    if let m5 = device.m5State, device.kind == .m5Dual {
                        LabeledContent("受理した目標温度", value: String(format: "%.2f ℃", M5LANProtocol.targetCelsius(m5.target)))
                        LabeledContent("適用ポンプ設定", value: String(format: "%.2f", m5.pump))
                        LabeledContent("ヒーター", value: m5.heater ? (m5.heating ? "加熱中" : "温度保持") : "停止")
                        if showDiagnostics {
                            LabeledContent("PPS実測電圧", value: m5.voltage.map { String(format: "%.2f V", $0) } ?? "—")
                        }
                    } else {
                        LabeledContent("実測圧力", value: device.status?.actualPressureKPa.map { String(format: "%.1f kPa", $0) } ?? "—")
                    }
                    if let date = device.lastResponse {
                        LabeledContent("応答", value: date.formatted(date: .omitted, time: .standard))
                    }
                    if showDiagnostics {
                        LabeledContent("Device State", value: device.status?.state ?? "—")
                        LabeledContent("受理した温度指令", value: device.status?.temperatureTarget.map { String(format: "%.2f", $0) } ?? "—")
                        LabeledContent("受理した硬さ指令", value: device.status?.stiffnessTarget.map { String(format: "%.2f", $0) } ?? "—")
                        LabeledContent("平均サンプル", value: String(lab.windowSampleCount))
                    }
                }.font(.subheadline).gelCard()
                notice
            }.padding(20)
        }.background(GelPalette.paper).navigationTitle("ゲル").navigationBarTitleDisplayMode(.inline)
    }

    private var vectorChart: some View {
        Chart {
            ForEach(lab.vectorHistory) { frame in
                LineMark(x: .value("時刻", frame.date), y: .value("指令", frame.state.temperature), series: .value("軸", "温度"))
                    .foregroundStyle(by: .value("軸", "温度"))
                LineMark(x: .value("時刻", frame.date), y: .value("指令", frame.state.stiffness), series: .value("軸", "硬さ"))
                    .foregroundStyle(by: .value("軸", "硬さ"))
            }
        }.chartYScale(domain: 0...1)
            .chartForegroundStyleScale(["温度": GelPalette.coral, "硬さ": GelPalette.blue])
            .frame(height: 160)
            .overlay { if lab.vectorHistory.isEmpty { Text("入力待ち").font(.caption).foregroundStyle(.secondary) } }
    }

    private var studyScreen: some View {
        Form {
            Section {
                TextField("匿名参加者ID", text: $participant)
            } header: { Text("参加者") } footer: { Text("参加同意・装置の校正・表面温度を確認してください。") }
            Section {
                LabeledContent("提示条件", value: "\(studyIndex + 1) / 6")
                Button("条件を設定") {
                    Task {
                        await lab.selectMode(.manual)
                        await lab.stop(reason: "条件を設定しました")
                        lab.manualTemperature = studyStates[studyIndex].temperature
                        lab.manualStiffness = studyStates[studyIndex].stiffness
                        lab.updateState()
                    }
                }
                outputControls
                Text("実測温度が安定してから触れてください。")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("温かさ: \(warmth) / 7", value: $warmth, in: 1...7)
                Stepper("硬さ: \(hardness) / 7", value: $hardness, in: 1...7)
                TextField("感じたこと", text: $impression, axis: .vertical).lineLimit(3...6)
                Button("記録する") {
                    let before = lab.trials.count
                    lab.addTrial(participant: participant, impression: impression, warmth: warmth, hardness: hardness)
                    if lab.trials.count > before {
                        impression = ""
                        warmth = 4
                        hardness = 4
                        studyIndex = (studyIndex + 1) % studyStates.count
                        Task { await lab.stop(reason: "記録しました") }
                    }
                }.disabled(participant.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("提示順をシャッフル") {
                    studyStates.shuffle()
                    studyIndex = 0
                    Task { await lab.stop(reason: "提示順を変更しました") }
                }
            } header: { Text("体験") }
            Section {
                Button("CSVを書き出す") { lab.export(study: true) }
                if let url = lab.exportURL { ShareLink("CSVを共有", item: url) }
                ForEach(lab.trials.reversed()) { trial in
                    VStack(alignment: .leading) {
                        Text("\(trial.participant) / \(trial.date.formatted(date: .omitted, time: .shortened))")
                        Text(trial.impression.isEmpty ? "—" : trial.impression)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("記録 \(lab.trials.count)件") }
            if !lab.notice.isEmpty { Section { notice } }
        }.scrollContentBackground(.hidden).background(GelPalette.paper).navigationTitle("記録")
    }

    private var settingsScreen: some View {
        Form {
            Section {
                Picker("接続方式", selection: $lab.connectionKind) {
                    ForEach(DeviceConnectionKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.onChange(of: lab.connectionKind) { _, _ in
                    focusedSettingsField = nil
                    Task { await lab.connectionSettingsChanged() }
                }
                TextField(lab.connectionKind == .m5Dual ? "http://m5-control.local" : "http://192.168.4.1", text: $lab.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedSettingsField, equals: .address)
                    .submitLabel(.done)
                    .onChange(of: lab.address) { _, _ in
                        Task { await lab.connectionSettingsChanged() }
                    }
                if lab.connectionKind == .m5Dual {
                    SecureField("M5画面のLAN PIN（8桁）", text: $lab.lanPIN)
                        .keyboardType(.numberPad)
                        .focused($focusedSettingsField, equals: .lanPIN)
                        .submitLabel(.done)
                        .onChange(of: lab.lanPIN) { _, _ in Task { await lab.connectionSettingsChanged() } }
                    Text("M5画面のURLとLAN PINを入力してください。PINは保存せず、M5の再起動時に変わります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(device.connected ? "再接続" : "接続") {
                    focusedSettingsField = nil
                    Task { await lab.connect() }
                }.disabled(device.busy)
                Text(deviceSummary).font(.caption)
            } header: { Text("M5Stack") }
            Section {
                Button("ヘルスケアのアクセス設定") { Task { await health.authorize() } }
                Button("データを更新") { Task { await health.refresh() } }
                Button("安静時心拍を基準にする") { lab.applyRestingBaseline() }
                    .disabled(health.restingHeartRate == nil)
                Text(health.status).font(.caption)
            } header: { Text("Apple Watch") }
            Section {
                Toggle("診断表示", isOn: $showDiagnostics)
                Button("信号ログを書き出す") { lab.export(study: false) }
                if let url = lab.exportURL { ShareLink("CSVを共有", item: url) }
                Button("記録を消去", role: .destructive) { Task { await lab.clearRecords() } }
            } header: { Text("表示と記録") }
            Section {
                NavigationLink("安全とプライバシー") { usageInformation }
            }
        }.scrollContentBackground(.hidden).background(GelPalette.paper).navigationTitle("設定")
            .scrollDismissesKeyboard(.interactively)
            .onSubmit { focusedSettingsField = nil }
            .onDisappear { focusedSettingsField = nil }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedSettingsField != nil {
                        Spacer()
                        Button("完了") { focusedSettingsField = nil }
                    }
                }
            }
    }

    private var usageInformation: some View {
        Form {
            Section("接続") {
                Text("iPhoneとM5Stackを同じWi-Fiへ接続してください。心拍計測はWatchから開始します。")
            }
            Section("安全") {
                Text("出力の開始は手動です。入力停止・通信断・バックグラウンド移行時は出力を停止します。")
                Text(lab.connectionKind == .m5Dual
                     ? "M5方式は通信が2秒途切れると停止します。温度指令は25〜50℃、ポンプは0 / 0.38 / 0.71 / 1の電流設定に対応し、圧力の実測値ではありません。"
                     : "デバイス側で6秒TTL、温度・圧力制限、センサ異常停止、独立した安全遮断を使用してください。")
                Text("温度・硬さ指令は0〜1の値です。触れる際は実測温度と装置の状態を確認してください。")
            }
            Section("プライバシー") {
                Text("音声は端末内で処理し、保存・送信しません。信号CSVには文字起こし本文を含めません。")
                Text("計測・体験記録はアプリ終了まで保持します。モデルは端末に保存します。")
            }
        }.navigationTitle("安全とプライバシー").navigationBarTitleDisplayMode(.inline)
    }

    private var deviceAttention: Bool {
        device.status?.state == "fault" || device.status?.state == "expired" || device.status?.error != nil
    }

    private var deviceSummary: String {
        guard device.connected else { return device.message }
        let state: String
        switch device.status?.state {
        case "active": state = "出力中"
        case "expired": state = "指令期限切れ"
        case "fault": state = "デバイス異常"
        case "starting": state = "センサー確認中"
        default: state = "接続済み"
        }
        return state + (device.status?.simulated == true ? " · 模擬" : "")
    }

    private var outputControls: some View {
        HStack(spacing: 12) {
            Button { Task { await lab.startOutput() } } label: {
                Label("出力開始", systemImage: "play.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(lab.armed || !lab.canStartOutput)
            Button(role: .destructive) { Task { await lab.stop() } } label: {
                Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }.controlSize(.large)
    }

    @ViewBuilder private var notice: some View {
        if !lab.notice.isEmpty {
            Text(lab.notice).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, value: Double, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).gelCard()
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(value.wrappedValue, specifier: range.upperBound > 1 ? "%.0f" : "%.2f") \(unit)")
                    .font(.subheadline.monospacedDigit())
            }
            Slider(value: value, in: range).tint(GelPalette.mint)
        }
    }

    private func preset(_ title: String, temperature: Double, stiffness: Double) -> some View {
        Button(title) {
            lab.manualTemperature = temperature
            lab.manualStiffness = stiffness
            lab.updateState()
        }.buttonStyle(.bordered)
    }
}

extension View {
    func gelCard() -> some View {
        padding(18).background(.white, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(GelPalette.ink.opacity(0.035), lineWidth: 1))
    }
}
