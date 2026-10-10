import Foundation

public struct VoiceFeatures: Equatable, Sendable {
    public let measuredAt: Date
    public let duration: TimeInterval
    public let rmsDecibels: Double
    public let activityRatio: Double
    public let voicedRatio: Double
    public let medianPitchHz: Double?
    public let pitchVariationSemitones: Double

    public var hasVoiceEvidence: Bool { activityRatio >= 0.2 && voicedRatio >= 0.15 }
    public var pauseRatio: Double { 1 - activityRatio }
}

public enum VoiceAnalyzer {
    public static func analyze(_ samples: [Float], sampleRate: Int = 16_000,
                               measuredAt: Date = Date()) -> VoiceFeatures? {
        guard sampleRate == 16_000, (8_000...160_000).contains(samples.count),
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1.5 }) else { return nil }
        let reduced = stride(from: 0, through: samples.count - 4, by: 4).map { offset in
            (0..<4).reduce(0.0) { $0 + Double(samples[offset + $1]) } / 4
        }
        var levels: [Double] = []
        var pitches: [Double] = []
        var frameCount = 0
        for offset in stride(from: 0, through: reduced.count - 160, by: 80) {
            let frame = Array(reduced[offset..<(offset + 160)])
            let average = frame.reduce(0, +) / Double(frame.count)
            let centered = frame.map { $0 - average }
            let power = centered.reduce(0) { $0 + $1 * $1 } / Double(centered.count)
            let decibels = 10 * log10(max(power, 0.000_000_000_001))
            frameCount += 1
            if decibels > -55 {
                levels.append(decibels)
                if let pitch = pitch(in: centered) { pitches.append(pitch) }
            }
        }
        let semitones = pitches.map { 12 * log2($0) }
        let meanPitch = semitones.isEmpty ? 0 : semitones.reduce(0, +) / Double(semitones.count)
        let variance = semitones.isEmpty ? 0
            : semitones.reduce(0) { $0 + pow($1 - meanPitch, 2) } / Double(semitones.count)
        return VoiceFeatures(measuredAt: measuredAt, duration: Double(samples.count) / Double(sampleRate),
                             rmsDecibels: median(levels) ?? -120,
                             activityRatio: Double(levels.count) / Double(frameCount),
                             voicedRatio: Double(pitches.count) / Double(frameCount),
                             medianPitchHz: median(pitches), pitchVariationSemitones: sqrt(variance))
    }

    private static func pitch(in frame: [Double]) -> Double? {
        let lags = Array(8...66)
        let correlations = lags.map { lag -> Double in
            var product = 0.0
            var firstPower = 0.0
            var secondPower = 0.0
            for offset in 0..<(frame.count - lag) {
                let first = frame[offset]
                let second = frame[offset + lag]
                product += first * second
                firstPower += first * first
                secondPower += second * second
            }
            let denominator = sqrt(firstPower * secondPower)
            return denominator > 0 ? product / denominator : 0
        }
        guard let maximum = correlations.max(), maximum >= 0.7 else { return nil }
        for index in 1..<(correlations.count - 1) {
            let current = correlations[index]
            guard current >= max(0.7, maximum * 0.9), current > correlations[index - 1],
                  current >= correlations[index + 1] else { continue }
            let curvature = correlations[index - 1] - 2 * current + correlations[index + 1]
            let adjustment = abs(curvature) > 0.000_001
                ? max(-0.5, min(0.5, 0.5 * (correlations[index - 1] - correlations[index + 1]) / curvature)) : 0
            return 4_000 / (Double(lags[index]) + adjustment)
        }
        return nil
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

public struct VoiceSignal: Equatable, Sendable {
    public let features: VoiceFeatures
    public let referenceDecibels: Double
    public let relativeStrength: Double
    public let modulation: Double

    public init(features: VoiceFeatures, referenceDecibels: Double = -30) {
        self.features = features
        self.referenceDecibels = referenceDecibels.isFinite ? max(-80, min(0, referenceDecibels)) : -30
        relativeStrength = HapticState.unit(0.5 + (features.rmsDecibels - self.referenceDecibels) / 30)
        modulation = HapticState.unit(features.pitchVariationSemitones / 6)
    }

    public var haptic: HapticState {
        guard features.hasVoiceEvidence else { return .neutral }
        return HapticState(temperature: 0.35 + 0.3 * features.activityRatio,
                           stiffness: 0.15 + 0.75 * (0.55 * relativeStrength + 0.45 * modulation))
    }
}

public enum SpeechExpressionMode: String, CaseIterable, Identifiable, Sendable {
    case combined = "ことば＋声"
    case voice = "声だけ"
    case text = "ことばだけ"
    public var id: String { rawValue }
}

public struct ExpressionState: Sendable {
    public let haptic: HapticState
    public let fresh: Bool
    public let usesVoice: Bool
    public let usesText: Bool
}

public enum ExpressionMapping {
    public static func map(text: ConversationSignal?, voice: VoiceSignal?, mode: SpeechExpressionMode,
                           now: Date = Date()) -> ExpressionState {
        let textFresh = text.map { (0...30).contains(now.timeIntervalSince($0.measuredAt)) } ?? false
        let voiceFresh = voice.map {
            (0...6).contains(now.timeIntervalSince($0.features.measuredAt)) && $0.features.hasVoiceEvidence
        } ?? false
        let usesVoice = mode != .text && voiceFresh
        let usesText = mode != .voice && textFresh
        let state: HapticState
        if usesVoice, let voice {
            if usesText, let text, !text.evidence.isEmpty {
                state = HapticState(temperature: text.haptic.temperature,
                                    stiffness: 0.35 * text.arousal + 0.65 * voice.haptic.stiffness)
            } else {
                state = voice.haptic
            }
        } else {
            state = usesText ? text?.haptic ?? .neutral : .neutral
        }
        return ExpressionState(haptic: state, fresh: usesVoice || usesText,
                               usesVoice: usesVoice, usesText: usesText)
    }
}
