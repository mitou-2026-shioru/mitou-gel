import SwiftUI
import UniformTypeIdentifiers

struct SpeechView: View {
    @ObservedObject var lab: LabModel
    @ObservedObject private var speech: SpeechModel
    @AppStorage("showDiagnostics") private var showDiagnostics = false
    @State private var text = ""
    @State private var importing = false
    @State private var importFailure: String?
    @State private var showingSettings = false

    init(lab: LabModel) {
        self.lab = lab
        speech = lab.speech
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("入力", selection: Binding(get: { lab.speechMode }, set: { value in
                    Task { await lab.changeSpeechMode(value) }
                })) {
                    ForEach(SpeechExpressionMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).disabled(speech.loading || speech.starting)
                VStack(spacing: 16) {
                    GelCompanion(state: lab.haptic, active: speech.transcribing || speech.recording,
                                 listening: speech.recording).frame(height: 165)
                    if speech.recording {
                        ProgressView(value: speech.level).tint(GelPalette.mint).accessibilityLabel("マイク入力レベル")
                    }
                    Button {
                        Task {
                            if speech.recording {
                                speech.stop()
                                await lab.stop(reason: "録音・出力を停止しました")
                            } else {
                                await lab.selectMode(.conversation)
                                await speech.start()
                            }
                        }
                    } label: {
                        Label(speech.recording ? "停止" : "話しかける",
                              systemImage: speech.recording ? "stop.fill" : "mic.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(speech.loading || speech.starting || (speech.transcribesSpeech && !speech.ready)
                                  || (!speech.recording && speech.transcribing))
                    if speech.starting || speech.transcribing {
                        ProgressView(speech.starting ? "マイクを準備中" : "文字起こし中").font(.caption)
                    }
                }.gelCard()
                if let failure = speech.failureMessage {
                    Label(failure, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(GelPalette.coral)
                }
                if speech.emotionEnabled, let failure = speech.emotionFailureMessage {
                    Label(failure, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(GelPalette.coral)
                }
                if speech.transcribesSpeech, !speech.ready {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("文字起こし", systemImage: "text.bubble").font(.headline)
                        if speech.loading {
                            ProgressView(value: speech.progress).tint(GelPalette.mint)
                        } else {
                            Button("モデルを準備") { Task { await speech.prepare(download: true) } }
                                .buttonStyle(.bordered)
                        }
                    }.gelCard()
                }
                if let result = speech.latestEmotion {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("音声分類 · 候補").font(.caption).foregroundStyle(.secondary)
                            Text(emotionLabel(result.topLabel)).font(.system(.title3, design: .rounded).bold())
                        }
                        Spacer()
                        Text(result.maximumProbability, format: .percent.precision(.fractionLength(0)))
                            .font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    }.gelCard()
                }
                if let signal = lab.conversation, lab.speechMode != .voice {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("ことば", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
                        Text(signal.text).font(.subheadline).textSelection(.enabled)
                    }.gelCard()
                }
                if lab.speechMode != .voice {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("ことばを入力", text: $text, axis: .vertical)
                            .lineLimit(2...4).padding(12).background(GelPalette.paper, in: RoundedRectangle(cornerRadius: 16))
                            .onChange(of: text) { _, value in if value.count > 1_000 { text = String(value.prefix(1_000)) } }
                        Button("送る") { Task { await submit(text) } }
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.gelCard()
                }
                if showDiagnostics { diagnostics }
            }.padding(20)
        }.background(GelPalette.paper).navigationTitle("ことば").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("音声設定")
                }
            }
            .task { if !speech.ready, lab.speechMode != .voice { await speech.prepare(download: false) } }
            .sheet(isPresented: $showingSettings) { audioSettings }
    }

    private var audioSettings: some View {
        NavigationStack {
            Form {
                Section("マイク") {
                    Picker("処理", selection: $speech.microphoneProcessing) {
                        ForEach(MicrophoneProcessing.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    Picker("向き", selection: $speech.microphonePosition) {
                        ForEach(MicrophonePosition.allCases) { position in Text(position.rawValue).tag(position) }
                    }
                }.disabled(speech.recording || speech.starting)
                Section("声") {
                    Toggle("音声分類", isOn: $speech.emotionEnabled).disabled(speech.recording || speech.starting)
                    Button("声の基準を設定") { speech.calibrateVoice() }
                        .disabled(!speech.recording || lab.voice?.features.hasVoiceEvidence != true)
                }
                if lab.speechMode != .voice {
                    Section("文字起こし") {
                        Picker("モデル", selection: $speech.selectedModel) {
                            ForEach(LocalSpeechModel.allCases) { model in Text(model.title).tag(model) }
                        }
                        if speech.loading { ProgressView(value: speech.progress).tint(GelPalette.mint) }
                        Button("ダウンロード") { Task { await speech.prepare(download: true) } }
                        Button("保存済みを読み込む") { Task { await speech.prepare(download: false) } }
                        Button("モデルを読み込む") { importFailure = nil; importing = true }
                    }.disabled(speech.loading || speech.recording || speech.transcribing)
                }
                Section {
                    Toggle("診断表示", isOn: $showDiagnostics)
                }
                if let failure = importFailure {
                    Section { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(GelPalette.coral) }
                }
            }.navigationTitle("音声設定").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { showingSettings = false }
                    }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let url): Task { await speech.importModel(from: url) }
                    case .failure(let error): importFailure = error.localizedDescription
                    }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label("マイク診断", systemImage: "waveform").font(.headline)
                Text(speech.microphoneRoute).font(.caption)
                if !speech.captureFormat.isEmpty { Text(speech.captureFormat).font(.caption2.monospacedDigit()) }
                Text("RMS \(speech.inputLevel.rmsDecibels, specifier: "%.1f") dBFS · peak \(speech.inputLevel.peakDecibels, specifier: "%.1f") dBFS")
                    .font(.caption.monospacedDigit())
                Text("受信 \(speech.capturedSeconds, specifier: "%.1f") 秒 · 破棄 \(speech.droppedBuffers)")
                    .font(.caption.monospacedDigit())
                Text(speech.message).font(.caption).foregroundStyle(.secondary)
                Text(speech.modelLabel).font(.caption).foregroundStyle(.secondary)
            }.gelCard()
            if let signal = lab.voice {
                let features = signal.features
                VStack(alignment: .leading, spacing: 10) {
                    Label("声の特徴", systemImage: "waveform.path").font(.headline)
                    LabeledContent("強さ", value: String(format: "%.1f dBFS", features.rmsDecibels))
                    LabeledContent("基準", value: String(format: "%.1f dBFS", signal.referenceDecibels))
                    LabeledContent("活動率", value: String(format: "%.0f%%", features.activityRatio * 100))
                    LabeledContent("有声音", value: String(format: "%.0f%%", features.voicedRatio * 100))
                    LabeledContent("高さ", value: features.medianPitchHz.map { String(format: "%.0f Hz", $0) } ?? "—")
                    LabeledContent("抑揚", value: String(format: "%.2f st", features.pitchVariationSemitones))
                }.font(.caption.monospacedDigit()).gelCard()
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("音声分類", systemImage: "cpu").font(.headline)
                Text(speech.emotionMessage).font(.caption).foregroundStyle(.secondary)
                if let result = speech.latestEmotion {
                    ForEach(result.probabilities.sorted { $0.key < $1.key }, id: \.key) { entry in
                        LabeledContent(emotionLabel(entry.key), value: entry.value.formatted(.percent.precision(.fractionLength(1))))
                    }
                    Text("分布の尖り \(result.observation.confidence, specifier: "%.2f")")
                    Text("valence \(result.observation.dimensions[.valence] ?? 0, specifier: "%.2f") · arousal \(result.observation.dimensions[.arousal] ?? 0, specifier: "%.2f")")
                    if let state = speech.latestAffect {
                        Text("平滑化後 \(state.valence, specifier: "%.2f"), \(state.arousal, specifier: "%.2f")")
                    }
                }
            }.font(.caption.monospacedDigit()).gelCard()
            if let signal = lab.conversation {
                VStack(alignment: .leading, spacing: 10) {
                    Label("文字の解析", systemImage: "text.magnifyingglass").font(.headline)
                    Text("valence \(signal.valence, specifier: "%.2f") · arousal \(signal.arousal, specifier: "%.2f")")
                    Text(signal.evidence.isEmpty ? "手がかりなし" : signal.evidence.joined(separator: " · "))
                    Text("置換した音声窓 \(speech.skippedClips)")
                }.font(.caption.monospacedDigit()).gelCard()
            }
        }
    }

    private func emotionLabel(_ label: String) -> String {
        ["anger": "怒り", "disgust": "嫌悪", "fear": "恐れ", "joy": "喜び", "neutral": "中立", "sadness": "悲しみ"][label] ?? label
    }

    private func submit(_ value: String) async {
        await lab.selectMode(.conversation)
        speech.analyzeText(value)
    }
}
