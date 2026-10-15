import Combine
import Foundation
import SwiftUI

enum InputMode: String, CaseIterable, Identifiable {
    case live = "Watch"
    case simulation = "模擬入力"
    case conversation = "ことば"
    case manual = "手動"
    var id: String { rawValue }
}

struct StudyTrial: Identifiable {
    let id = UUID()
    let date: Date
    let participant: String
    let state: HapticState
    let actualTemperature: Double?
    let deviceState: String
    let simulated: Bool
    let impression: String
    let warmth: Int
    let hardness: Int
    let connectionKind: DeviceConnectionKind
    let appliedTemperatureTarget: Double?
    let appliedStiffnessTarget: Double?
}

@MainActor
final class LabModel: ObservableObject {
    @Published var mode: InputMode = .simulation
    @Published var pipeline = SignalPipeline()
    @Published var internalState = SignalPipeline().state()
    @Published var haptic: HapticState = .neutral
    @Published private(set) var conversation: ConversationSignal?
    @Published private(set) var voice: VoiceSignal?
    @Published private(set) var speechMode: SpeechExpressionMode = .combined
    @Published private(set) var windowSeconds = 10
    @Published private(set) var windowSampleCount = 0
    @Published private(set) var vectorHistory: [HapticFrame] = []
    @Published var manualTemperature = 0.5
    @Published var manualStiffness = 0.0
    @Published var simulatedHR = 75.0
    @Published var armed = false
    @Published var address = UserDefaults.standard.string(forKey: "deviceAddress") ?? "http://192.168.4.1"
    @Published var connectionKind = DeviceConnectionKind(rawValue: UserDefaults.standard.string(forKey: "deviceConnectionKind") ?? "") ?? .gelLink
    @Published var lanPIN = ""
    @Published var notice = ""
    @Published var trials: [StudyTrial] = []
    @Published var exportURL: URL?
    let bridge = WatchBridge()
    let health = HealthReader()
    let device = DeviceClient()
    let speech = SpeechModel()
    private let mapping = HapticMapping()
    private var hapticWindow = HapticWindow()
    private var logs: [[String]] = []
    private var active = true
    private var configuredAddress: String?
    private var tickCount = 0
    private var controlGeneration = 0
    private var healthTask: Task<Void, Never>?

    init() {
        device.onOutputLost = { [weak self] reason in
            guard let self, self.armed else { return }
            self.armed = false
            self.controlGeneration += 1
            self.notice = reason
            self.syncCompanion()
        }
        bridge.onReading = { [weak self] reading in
            guard let self, self.mode == .live else { return }
            self.ingest(reading)
        }
        speech.onSignal = { [weak self] signal in
            guard let self, self.mode == .conversation, self.active,
                  (0...30).contains(Date().timeIntervalSince(signal.measuredAt)),
                  self.conversation.map({ signal.measuredAt > $0.measuredAt }) ?? true else { return }
            self.conversation = signal
            self.updateState()
        }
        speech.onVoice = { [weak self] signal in
            guard let self, self.mode == .conversation, self.active else { return }
            if let signal {
                guard (0...6).contains(Date().timeIntervalSince(signal.features.measuredAt)),
                      self.voice.map({ signal.features.measuredAt >= $0.features.measuredAt }) ?? true else { return }
            }
            self.voice = signal
            self.updateState()
        }
    }

    func run() async {
        let clock = ContinuousClock()
        var cadence = HapticCadence(start: clock.now)
        while !Task.isCancelled {
            if active {
                let cycleGeneration = controlGeneration
                tickCount += 1
                if mode == .simulation {
                    let fluctuation = sin(Date().timeIntervalSince1970 / 8) * 2
                    ingest(SensorReading(heartRate: simulatedHR + fluctuation, source: .simulation))
                }
                if tickCount % 5 == 0, mode == .live, healthTask == nil {
                    healthTask = Task { [weak self] in
                        guard let self else { return }
                        defer { self.healthTask = nil }
                        await self.health.refresh()
                        guard self.active, self.mode == .live, !Task.isCancelled else { return }
                        let liveWatchIsFresh = self.pipeline.latest?.source == .watch && self.pipeline.state().fresh
                        if !liveWatchIsFresh, let reading = self.health.reading { self.ingest(reading) }
                    }
                }
                updateState(record: true)
                if armed {
                    if !inputFresh {
                        await stop(reason: "有効な新しい入力がないため出力を停止しました")
                    } else {
                        await device.send(state: haptic, enabled: true)
                        if armed, cycleGeneration == controlGeneration,
                           (!device.connected || device.status?.permitsControl != true) {
                            await stop(reason: "通信断またはデバイス異常のため出力を停止しました")
                        }
                    }
                } else if configuredAddress != nil {
                    await device.poll()
                }
                syncCompanion()
                logSnapshot()
            }
            cadence.advance(past: clock.now)
            do { try await clock.sleep(until: cadence.deadline) } catch { break }
        }
    }

    func selectMode(_ value: InputMode) async {
        guard mode != value else { return }
        mode = value
        speech.stop()
        conversation = nil
        voice = nil
        pipeline.reset()
        resetWindow()
        updateState()
        await stop(reason: "入力変更で出力を停止しました")
    }

    func changeWindow(_ seconds: Int) async {
        guard [10, 30, 60].contains(seconds), windowSeconds != seconds else { return }
        windowSeconds = seconds
        resetWindow()
        updateState()
        await stop(reason: "時間窓の変更で出力を停止しました")
    }

    func changeSpeechMode(_ value: SpeechExpressionMode) async {
        guard speechMode != value else { return }
        speechMode = value
        speech.setTranscriptionEnabled(value != .voice)
        conversation = nil
        voice = nil
        resetWindow()
        updateState()
        await stop(reason: "録音・出力を停止しました")
    }

    var expression: ExpressionState {
        ExpressionMapping.map(text: conversation, voice: voice, mode: speechMode)
    }

    var inputFresh: Bool {
        switch mode {
        case .manual: true
        case .conversation: expression.fresh
        case .live, .simulation: internalState.fresh
        }
    }

    func connect() async {
        await stop(reason: "デバイスを接続しています")
        guard device.configure(address: address, kind: connectionKind, pin: lanPIN) else {
            configuredAddress = nil
            notice = device.message
            return
        }
        configuredAddress = address
        UserDefaults.standard.set(address, forKey: "deviceAddress")
        UserDefaults.standard.set(connectionKind.rawValue, forKey: "deviceConnectionKind")
        await device.connect()
        notice = device.message
    }

    var canStartOutput: Bool {
        active && configuredAddress != nil && device.connected && !device.busy && device.status?.permitsControl == true
            && device.matches(address: address, kind: connectionKind, pin: lanPIN)
    }

    func connectionSettingsChanged() async {
        await stop(reason: "接続設定が変わりました。接続し直してください")
        configuredAddress = nil
    }

    func startOutput() async {
        updateState()
        guard canStartOutput else {
            notice = "接続設定とM5の状態を確認し、デバイスに接続してください"
            return
        }
        guard inputFresh else {
            notice = "新しい入力がありません"
            return
        }
        armed = true
        let startGeneration = controlGeneration
        notice = "出力中"
        let started = await device.start(state: haptic)
        if armed, startGeneration == controlGeneration,
           (!started || !device.connected || device.status?.permitsControl != true) {
            await stop(reason: device.message)
        }
        syncCompanion()
    }

    func stop(reason: String = "出力を停止しました") async {
        armed = false
        controlGeneration += 1
        notice = reason
        syncCompanion()
        if configuredAddress != nil { await device.send(state: .neutral, enabled: false) }
    }

    func setActive(_ value: Bool) async {
        active = value
        speech.setActive(value)
        if !value {
            healthTask?.cancel()
            resetWindow()
            await stop(reason: "出力を停止しました")
        }
    }

    func calibrate() {
        if pipeline.calibrate() {
            notice = "心拍の基準を設定しました"
            updateState()
        } else { notice = "新しい心拍サンプルが3件以上必要です" }
    }

    func applyRestingBaseline() {
        guard let baseline = health.restingHeartRate, (25...240).contains(baseline) else { return }
        pipeline.baseline = baseline
        updateState()
    }

    func updateState(record: Bool = false) {
        internalState = pipeline.state()
        let raw: HapticState
        switch mode {
        case .manual: raw = HapticState(temperature: manualTemperature, stiffness: manualStiffness)
        case .conversation: raw = expression.haptic
        case .live, .simulation: raw = mapping.map(internalState)
        }
        let now = Date()
        if record, mode != .manual {
            hapticWindow.append(HapticFrame(date: now, state: raw), now: now)
        }
        windowSampleCount = hapticWindow.count(seconds: Double(windowSeconds), now: now)
        haptic = mode == .manual ? raw : hapticWindow.mean(seconds: Double(windowSeconds), now: now) ?? raw
        if record {
            vectorHistory.removeAll { now.timeIntervalSince($0.date) > 120 }
            vectorHistory.append(HapticFrame(date: now, state: haptic))
        }
    }

    private func resetWindow() {
        hapticWindow.reset()
        windowSampleCount = 0
        vectorHistory.removeAll()
    }

    private func syncCompanion() {
        bridge.sendCompanion(CompanionState(haptic: haptic, armed: armed, input: mode.rawValue))
    }

    private func ingest(_ reading: SensorReading) {
        var enriched = reading
        if enriched.source != .simulation && enriched.hrvMilliseconds == nil {
            enriched.hrvMilliseconds = health.hrvValue
            enriched.hrvMeasuredAt = health.hrvDate
        }
        if pipeline.ingest(enriched) { updateState() }
    }

    func addTrial(participant: String, impression: String, warmth: Int, hardness: Int) {
        guard mode == .manual, armed, device.connected, device.status?.state == "active",
              let command = device.lastCommand, command.enabled,
              device.status?.acceptedCommandID == command.commandID,
              command.temperature == haptic.temperature, command.stiffness == haptic.stiffness else {
            notice = "手動モードで指定した触覚の応答を確認してから記録してください"
            return
        }
        trials.append(StudyTrial(date: Date(), participant: participant, state: haptic,
                                 actualTemperature: device.status?.actualTemperature,
                                 deviceState: device.status?.state ?? "unknown",
                                 simulated: device.status?.simulated ?? false,
                                 impression: impression, warmth: warmth, hardness: hardness,
                                 connectionKind: device.kind,
                                 appliedTemperatureTarget: device.status?.temperatureTarget,
                                 appliedStiffnessTarget: device.status?.stiffnessTarget))
        notice = "体験記録を保存しました（アプリ終了時に消去・CSV書き出し可）"
    }

    func export(study: Bool) {
        var content: String
        if study {
            content = CSV.row(["timestamp", "participant", "temperature", "stiffness", "actual_temperature_c",
                               "device_state", "simulated", "warmth_1_7", "hardness_1_7", "impression",
                               "connection_kind", "applied_temperature_target", "applied_stiffness_target"])
            for trial in trials {
                content += CSV.row([trial.date.ISO8601Format(), trial.participant,
                    String(trial.state.temperature), String(trial.state.stiffness),
                    trial.actualTemperature.map(String.init(describing:)) ?? "", trial.deviceState,
                    String(trial.simulated), String(trial.warmth), String(trial.hardness), trial.impression,
                    trial.connectionKind.rawValue, trial.appliedTemperatureTarget.map(String.init(describing:)) ?? "",
                    trial.appliedStiffnessTarget.map(String.init(describing:)) ?? ""])
            }
        } else {
            content = CSV.row(["timestamp", "mode", "source", "heart_rate", "sample_timestamp", "hrv_ms", "hrv_timestamp",
                               "baseline", "arousal", "delta", "trend_bpm_min", "fresh", "temperature_target",
                               "stiffness_target", "actual_temperature_c", "actual_pressure_kpa", "device_state",
                               "armed", "simulated", "command_id", "window_seconds", "window_samples",
                               "expression_valence", "expression_arousal", "expression_evidence_count",
                               "speech_mode", "voice_rms_db", "voice_activity_ratio", "voice_voiced_ratio",
                               "voice_pitch_hz", "voice_pitch_variation_st", "voice_reference_db",
                               "voice_measured_at", "expression_uses_voice", "audio_emotion_label",
                               "audio_emotion_max_probability", "audio_emotion_confidence", "audio_emotion_valence",
                               "audio_emotion_arousal", "audio_emotion_measured_at", "audio_emotion_fresh",
                               "audio_emotion_anger", "audio_emotion_disgust", "audio_emotion_fear",
                               "audio_emotion_joy", "audio_emotion_neutral", "audio_emotion_sadness",
                               "connection_kind", "applied_temperature_target", "applied_stiffness_target",
                               "m5_target_c", "m5_pump_setting", "m5_heater_enabled", "m5_heating", "m5_pps_v"])
            content += logs.map(CSV.row).joined()
        }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gellink-\(study ? "study" : "signals")-\(UUID().uuidString).csv")
            try content.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch { notice = error.localizedDescription }
    }

    func clearRecords() async {
        speech.stop()
        await stop(reason: "アプリ内の記録を消去しました")
        logs.removeAll()
        trials.removeAll()
        conversation = nil
        voice = nil
        speech.clear()
        pipeline.reset()
        resetWindow()
        updateState()
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
        notice = "アプリ内の記録を消去しました"
    }

    private func logSnapshot() {
        let latest = pipeline.latest
        let emotion = speech.latestEmotion
        logs.append([Date().ISO8601Format(), mode.rawValue, latest?.source.rawValue ?? "",
            latest.map { String($0.heartRate) } ?? "", latest?.measuredAt.ISO8601Format() ?? "",
            latest?.hrvMilliseconds.map(String.init(describing:)) ?? "", latest?.hrvMeasuredAt?.ISO8601Format() ?? "",
            String(internalState.baseline), String(internalState.arousal), String(internalState.delta),
            String(internalState.trendPerMinute), String(inputFresh), String(haptic.temperature),
            String(haptic.stiffness), device.status?.actualTemperature.map(String.init(describing:)) ?? "",
            device.status?.actualPressureKPa.map(String.init(describing:)) ?? "", device.status?.state ?? "disconnected",
            String(armed), String(device.status?.simulated ?? false), device.lastCommand?.commandID.uuidString ?? "",
            String(windowSeconds), String(windowSampleCount), conversation.map { String($0.valence) } ?? "",
            conversation.map { String($0.arousal) } ?? "", conversation.map { String($0.evidence.count) } ?? "",
            speechMode.rawValue, voice.map { String($0.features.rmsDecibels) } ?? "",
            voice.map { String($0.features.activityRatio) } ?? "", voice.map { String($0.features.voicedRatio) } ?? "",
            voice?.features.medianPitchHz.map(String.init(describing:)) ?? "",
            voice.map { String($0.features.pitchVariationSemitones) } ?? "",
            voice.map { String($0.referenceDecibels) } ?? "", voice?.features.measuredAt.ISO8601Format() ?? "",
            String(expression.usesVoice), emotion?.topLabel ?? "",
            emotion.map { String($0.maximumProbability) } ?? "",
            emotion.map { String($0.observation.confidence) } ?? "",
            emotion?.observation.dimensions[.valence].map(String.init(describing:)) ?? "",
            emotion?.observation.dimensions[.arousal].map(String.init(describing:)) ?? "",
            emotion?.observation.measuredAt.ISO8601Format() ?? "",
            String(emotion.map { (0...6).contains(Date().timeIntervalSince($0.observation.measuredAt)) } ?? false),
            emotion?.probabilities["anger"].map(String.init(describing:)) ?? "",
            emotion?.probabilities["disgust"].map(String.init(describing:)) ?? "",
            emotion?.probabilities["fear"].map(String.init(describing:)) ?? "",
            emotion?.probabilities["joy"].map(String.init(describing:)) ?? "",
            emotion?.probabilities["neutral"].map(String.init(describing:)) ?? "",
            emotion?.probabilities["sadness"].map(String.init(describing:)) ?? "",
            device.kind.rawValue, device.status?.temperatureTarget.map(String.init(describing:)) ?? "",
            device.status?.stiffnessTarget.map(String.init(describing:)) ?? "",
            device.m5State.map { String(M5LANProtocol.targetCelsius($0.target)) } ?? "",
            device.m5State.map { String($0.pump) } ?? "",
            device.m5State.map { String($0.heater) } ?? "",
            device.m5State.map { String($0.heating) } ?? "",
            device.m5State?.voltage.map(String.init(describing:)) ?? ""])
        if logs.count > 1_800 { logs.removeFirst(logs.count - 1_800) }
    }
}
