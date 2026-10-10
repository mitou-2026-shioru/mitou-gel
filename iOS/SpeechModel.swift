import AVFoundation
import Combine
import Foundation
import WhisperKit

enum LocalSpeechModel: String, CaseIterable, Identifiable {
    case base = "openai_whisper-base"
    case tiny = "openai_whisper-tiny"
    case turbo = "openai_whisper-large-v3-v20240930_626MB"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .base: "Base / 多言語"
        case .tiny: "Tiny / 軽量実験"
        case .turbo: "Turbo / 日本語精度重視"
        }
    }
}

enum MicrophoneProcessing: String, CaseIterable, Identifiable {
    case normal = "通常録音"
    case measurement = "特徴計測"
    var id: String { rawValue }
    var sessionMode: AVAudioSession.Mode { self == .normal ? .default : .measurement }
}

enum MicrophonePosition: String, CaseIterable, Identifiable {
    case front = "画面側"
    case bottom = "下側"
    case automatic = "内蔵自動"
    var id: String { rawValue }
}

@MainActor
final class SpeechModel: ObservableObject {
    @Published var selectedModel: LocalSpeechModel = .base
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var recording = false
    @Published private(set) var starting = false
    @Published private(set) var transcribing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var level = 0.0
    @Published var microphoneProcessing: MicrophoneProcessing = .normal
    @Published var microphonePosition: MicrophonePosition = .front
    @Published private(set) var microphoneRoute = "録音開始時に内蔵マイクを選択します"
    @Published private(set) var captureFormat = ""
    @Published private(set) var inputLevel: AudioInputLevel = .silence
    @Published private(set) var capturedSeconds = 0.0
    @Published private(set) var droppedBuffers = 0
    @Published private(set) var message = "まずモデルを準備してね。文字入力は今すぐ使えるよ。"
    @Published private(set) var failureMessage: String?
    @Published private(set) var emotionFailureMessage: String?
    @Published private(set) var latest: ConversationSignal?
    @Published private(set) var latestVoice: VoiceSignal?
    @Published private(set) var latestEmotion: AudioEmotionResult?
    @Published private(set) var latestAffect: AffectState?
    @Published var emotionEnabled = true
    @Published private(set) var emotionMessage = "学習済みの音声分類を参考表示します。触覚指令には使いません。"
    @Published private(set) var transcribesSpeech = true
    @Published private(set) var voiceReferenceDecibels = -30.0
    @Published private(set) var modelLabel = "モデル未準備"
    @Published private(set) var skippedClips = 0
    var onSignal: ((ConversationSignal) -> Void)?
    var onVoice: ((VoiceSignal?) -> Void)?
    private var whisper: WhisperKit?
    private var emotionModel: AudioEmotionModel?
    private var affectBuffer = AffectBuffer()
    private var engine: AVAudioEngine?
    private var captureTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var audioSamples: [Float] = []
    private var voiceSamples: [Float] = []
    private var nextClip: (samples: [Float], date: Date, energy: Double)?
    private var generation = 0
    private var active = true
    private var interruptionObserver: AnyCancellable?
    private var routeObserver: AnyCancellable?
    private var captureRouteSignature: String?

    init() {
        interruptionObserver = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.stop() } }
        routeObserver = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.checkAudioRoute() } }
    }

    func prepare(download: Bool) async {
        guard !loading, !recording, !transcribing else { return }
        failureMessage = nil
        loading = true
        ready = false
        whisper = nil
        progress = 0
        defer { loading = false }
        do {
            let root = try modelRoot()
            let key = "speechModelPath-" + selectedModel.rawValue
            var folder: URL?
            if let relative = UserDefaults.standard.string(forKey: key) {
                let cached = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: cached.path) { folder = cached }
            }
            if folder == nil {
                guard download else {
                    message = "保存済みモデルがないよ。「モデルをダウンロード」で準備してね。"
                    return
                }
                message = "Core MLモデルをダウンロード中。Wi-Fiがおすすめ。"
                folder = try await WhisperKit.download(variant: selectedModel.rawValue, downloadBase: root) {
                    [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in self?.progress = HapticState.unit(fraction) }
                }
            }
            guard let folder else { return }
            message = "端末内モデルを読み込んでいるよ。初回は少し時間がかかるよ。"
            whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: root,
                verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
            UserDefaults.standard.set(String(folder.path.dropFirst(root.path.count + 1)), forKey: key)
            ready = true
            progress = 1
            modelLabel = selectedModel.title
            message = "準備できたよ。音声認識はこの端末の中で動くよ。"
        } catch {
            message = "モデルの準備に失敗: " + error.localizedDescription
            failureMessage = message
        }
    }

    func importModel(from source: URL) async {
        guard !loading, !recording, !transcribing else { return }
        failureMessage = nil
        loading = true
        ready = false
        whisper = nil
        defer { loading = false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var copy: URL?
        do {
            let names = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
            guard names.allSatisfy({ name in
                ["mlmodelc", "mlpackage"].contains { suffix in
                    FileManager.default.fileExists(atPath: source.appendingPathComponent(name + "." + suffix).path)
                }
            }) else { throw SpeechFailure.invalidModel }
            let root = try modelRoot()
            let destination = root.appendingPathComponent("Imported-" + UUID().uuidString)
            copy = destination
            try FileManager.default.copyItem(at: source, to: destination)
            message = "持ち込んだCore MLモデルを読み込み中。"
            whisper = try await WhisperKit(WhisperKitConfig(modelFolder: destination.path, tokenizerFolder: root,
                verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
            ready = true
            modelLabel = "持ち込み / " + source.lastPathComponent
            message = "持ち込みモデルを使うよ。再起動後はもう一度選んでね。"
        } catch {
            if let copy { try? FileManager.default.removeItem(at: copy) }
            message = "持ち込みモデルを読み込めません: " + error.localizedDescription
            failureMessage = message
        }
    }

    func start() async {
        guard !loading, !recording, !transcribing, !starting, active else { return }
        failureMessage = nil
        guard ready || !transcribesSpeech else {
            message = "文字起こしモデルを準備するか、「声だけ」を選んでね。"
            return
        }
        starting = true
        emotionFailureMessage = nil
        defer { starting = false }
        let requestGeneration = generation
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard permitted else {
            message = "設定でマイクの使用を許可してください"
            failureMessage = message
            return
        }
        guard requestGeneration == generation, active else {
            message = "前面で「話しかける」をもう一度押してね。録音は自動では再開しないよ。"
            failureMessage = "もう一度「話しかける」を押してください"
            return
        }
        if emotionEnabled, emotionModel == nil {
            do {
                guard let modelURL = Bundle.main.url(forResource: "VoiceCircumplex", withExtension: "mlmodelc"),
                      let metadataURL = Bundle.main.url(forResource: "VoiceCircumplex", withExtension: "json") else {
                    throw SpeechFailure.missingEmotionModel
                }
                emotionModel = try await Task.detached(priority: .utility) {
                    try AudioEmotionModel(modelURL: modelURL, metadataURL: metadataURL)
                }.value
            } catch {
                emotionMessage = "音声分類を利用できません: " + error.localizedDescription
                emotionFailureMessage = emotionMessage
            }
        }
        guard requestGeneration == generation, active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: microphoneProcessing.sessionMode)
            try session.setActive(true)
            try selectMicrophone(session)
            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                  channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw SpeechFailure.microphoneUnavailable
            }
            captureFormat = "\(Int(inputFormat.sampleRate)) Hz · \(inputFormat.channelCount) ch → 16000 Hz · mono"
            updateAudioRoute(session)
            captureRouteSignature = Self.routeSignature(session)
            let captureGeneration = generation
            let stream = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(16))
            input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 32)
                guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
                var consumed = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }
                guard error == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
                if case .dropped = stream.continuation.yield(samples) {
                    Task { @MainActor [weak self] in
                        guard let self, self.recording, self.generation == captureGeneration else { return }
                        self.droppedBuffers += 1
                    }
                }
            }
            engine = audioEngine
            continuation = stream.continuation
            audioSamples.removeAll(keepingCapacity: true)
            voiceSamples.removeAll(keepingCapacity: true)
            skippedClips = 0
            droppedBuffers = 0
            capturedSeconds = 0
            inputLevel = .silence
            try audioEngine.start()
            recording = true
            message = transcribesSpeech ? "声の特徴は2秒、文字起こしは8秒の窓で解析するよ。"
                : "声の特徴を2秒ごとに解析するよ。文字起こしはしないよ。"
            captureTask = Task { [weak self] in
                for await samples in stream.stream {
                    guard let self, !Task.isCancelled, self.recording, self.generation == captureGeneration else { break }
                    guard let inputLevel = AudioInputLevel.analyze(samples) else { continue }
                    self.inputLevel = inputLevel
                    self.level = inputLevel.meter
                    self.capturedSeconds += Double(samples.count) / 16_000
                    if self.transcribesSpeech { self.audioSamples.append(contentsOf: samples) }
                    self.voiceSamples.append(contentsOf: samples)
                    while self.voiceSamples.count >= 32_000 {
                        let clip = Array(self.voiceSamples.prefix(32_000))
                        self.voiceSamples.removeFirst(32_000)
                        let date = Date()
                        let features = await Task.detached(priority: .utility) {
                            VoiceAnalyzer.analyze(clip, measuredAt: date)
                        }.value
                        guard !Task.isCancelled, self.recording, self.generation == captureGeneration else { break }
                        self.latestVoice = features.map { VoiceSignal(features: $0, referenceDecibels: self.voiceReferenceDecibels) }
                        self.onVoice?(self.latestVoice)
                        if self.emotionEnabled, let model = self.emotionModel {
                            do {
                                let result = try await model.classify(clip, measuredAt: date)
                                guard !Task.isCancelled, self.recording, self.generation == captureGeneration else { break }
                                self.latestEmotion = result
                                self.emotionFailureMessage = nil
                                if let result {
                                    self.affectBuffer.ingest(result.observation)
                                    self.latestAffect = AffectFusion.fuse(self.affectBuffer.observations, now: Date())
                                    self.emotionMessage = "音声分類とラッセル座標は参考表示。温度・硬さ指令とは別です。"
                                } else {
                                    self.affectBuffer.reset()
                                    self.latestAffect = nil
                                    self.emotionMessage = "有声音の手がかり不足。感情ラベルは表示しません。"
                                }
                            } catch {
                                guard !Task.isCancelled, self.recording, self.generation == captureGeneration else { break }
                                self.latestEmotion = nil
                                self.latestAffect = nil
                                self.affectBuffer.reset()
                                self.emotionMessage = "音声分類に失敗: " + error.localizedDescription
                                self.emotionFailureMessage = self.emotionMessage
                            }
                        }
                    }
                    guard !Task.isCancelled, self.recording, self.generation == captureGeneration else { break }
                    while self.transcribesSpeech, self.audioSamples.count >= 128_000 {
                        let clip = Array(self.audioSamples.prefix(128_000))
                        self.audioSamples.removeFirst(128_000)
                        let energy = Self.energy(clip)
                        let acceptsSpeech = await Task.detached(priority: .utility) {
                            SpeechAudioGate.accepts(clip)
                        }.value
                        guard !Task.isCancelled, self.recording, self.generation == captureGeneration else { break }
                        if acceptsSpeech { self.enqueue(clip, date: Date(), energy: energy) }
                    }
                }
            }
        } catch {
            stop()
            message = "録音を開始できません: " + error.localizedDescription
            failureMessage = message
        }
    }

    func stop() {
        generation += 1
        recording = false
        failureMessage = nil
        emotionFailureMessage = nil
        if ready || !transcribesSpeech { message = "聞くのをやめたよ。録音は保存していないよ。" }
        captureTask?.cancel()
        captureTask = nil
        continuation?.finish()
        continuation = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        decodeTask?.cancel()
        nextClip = nil
        audioSamples.removeAll()
        voiceSamples.removeAll()
        latestVoice = nil
        latestEmotion = nil
        latestAffect = nil
        affectBuffer.reset()
        onVoice?(nil)
        level = 0
        inputLevel = .silence
        captureRouteSignature = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setActive(_ value: Bool) {
        active = value
        if !value { stop() }
    }

    func analyzeText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let signal = ConversationSignal(text: trimmed)
        latest = signal
        onSignal?(signal)
    }

    func setTranscriptionEnabled(_ value: Bool) {
        stop()
        transcribesSpeech = value
        message = value ? "文字起こしにはモデルの準備が必要だよ。文字入力は今すぐ使えるよ。"
            : "「声だけ」は文字起こしモデル不要。話しかけると声の特徴を解析するよ。"
    }

    func calibrateVoice() {
        guard recording, let features = latestVoice?.features, features.hasVoiceEvidence,
              (0...6).contains(Date().timeIntervalSince(features.measuredAt)) else { return }
        voiceReferenceDecibels = features.rmsDecibels
        latestVoice = VoiceSignal(features: features, referenceDecibels: voiceReferenceDecibels)
        onVoice?(latestVoice)
        message = "いまの声の強さを基準にしたよ。感情の校正ではないよ。"
    }

    func clear() {
        latest = nil
        latestVoice = nil
        latestEmotion = nil
        latestAffect = nil
        affectBuffer.reset()
        onVoice?(nil)
    }

    private func enqueue(_ samples: [Float], date: Date, energy: Double) {
        if nextClip != nil { skippedClips += 1 }
        nextClip = (samples, date, energy)
        guard decodeTask == nil, let whisper else { return }
        let decodeGeneration = generation
        transcribing = true
        decodeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.transcribing = false; self.decodeTask = nil }
            while let clip = self.nextClip, self.generation == decodeGeneration, !Task.isCancelled {
                self.nextClip = nil
                do {
                    let options = DecodingOptions(language: "ja", temperatureFallbackCount: 1, sampleLength: 128,
                        skipSpecialTokens: true, withoutTimestamps: true, concurrentWorkerCount: 1)
                    let results = try await whisper.transcribe(audioArray: clip.samples, decodeOptions: options)
                    guard self.generation == decodeGeneration, self.recording, !Task.isCancelled else { break }
                    let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, text != "[BLANK_AUDIO]" {
                        let signal = ConversationSignal(text: text, measuredAt: clip.date, audioEnergy: clip.energy)
                        self.latest = signal
                        self.onSignal?(signal)
                        self.failureMessage = nil
                    }
                } catch {
                    if !Task.isCancelled {
                        self.message = "音声解析に失敗: " + error.localizedDescription
                        self.failureMessage = self.message
                    }
                }
            }
        }
    }

    private func selectMicrophone(_ session: AVAudioSession) throws {
        guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        if let sources = microphone.dataSources, !sources.isEmpty {
            let source: AVAudioSessionDataSourceDescription?
            switch microphonePosition {
            case .front:
                source = sources.first { $0.orientation == .front }
                    ?? sources.first { $0.orientation == .bottom || $0.location == .lower }
                    ?? sources.first
            case .bottom:
                source = sources.first { $0.orientation == .bottom || $0.location == .lower } ?? sources.first
            case .automatic:
                source = nil
            }
            try microphone.setPreferredDataSource(source)
        }
        try session.setPreferredInput(microphone)
    }

    private func updateAudioRoute(_ session: AVAudioSession) {
        let inputs = session.currentRoute.inputs.map { port in
            let source = port.selectedDataSource.map { " / " + $0.dataSourceName } ?? ""
            return port.portName + source
        }
        microphoneRoute = inputs.isEmpty ? "マイク入力なし" : inputs.joined(separator: " · ")
    }

    private static func routeSignature(_ session: AVAudioSession) -> String {
        session.currentRoute.inputs.map { port in
            port.uid + ":" + (port.selectedDataSource?.dataSourceID.stringValue ?? "")
        }.joined(separator: "|")
    }

    private func checkAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        guard recording else { return }
        if captureRouteSignature != Self.routeSignature(session)
            || engine?.inputNode.outputFormat(forBus: 0).sampleRate != session.sampleRate {
            stop()
            message = "マイク経路が変わったので停止したよ。経路を確認して「話しかける」を押してね。"
            failureMessage = "マイク入力が変わりました。もう一度開始してください"
        }
        updateAudioRoute(session)
    }

    private static func energy(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return HapticState.unit((20 * log10(max(sqrt(mean), 0.000_001)) + 50) / 50)
    }

    private func modelRoot() throws -> URL {
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true).appendingPathComponent("SpeechModels")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return root
    }
}

private enum SpeechFailure: LocalizedError {
    case invalidModel
    case microphoneUnavailable
    case missingEmotionModel
    var errorDescription: String? {
        switch self {
        case .invalidModel: "MelSpectrogram・AudioEncoder・TextDecoderを含むWhisperKit互換Core MLフォルダが必要です。"
        case .microphoneUnavailable: "利用可能なマイク入力がありません。"
        case .missingEmotionModel: "同梱の音声分類モデルが見つかりません。"
        }
    }
}
