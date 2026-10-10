import Foundation

public struct AudioInputLevel: Equatable, Sendable {
    public let rmsDecibels: Double
    public let peakDecibels: Double
    public var meter: Double { HapticState.unit((rmsDecibels + 70) / 60) }
    public static let silence = AudioInputLevel(rmsDecibels: -120, peakDecibels: -120)

    public static func analyze(_ samples: [Float]) -> AudioInputLevel? {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1.5 }) else { return nil }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let peak = samples.reduce(0.0) { max($0, abs(Double($1))) }
        return AudioInputLevel(rmsDecibels: 10 * log10(max(power, 0.000_000_000_001)),
                               peakDecibels: 20 * log10(max(peak, 0.000_001)))
    }
}

public enum SpeechAudioGate {
    public static func accepts(_ samples: [Float]) -> Bool {
        guard (8_000...128_000).contains(samples.count), let level = AudioInputLevel.analyze(samples) else { return false }
        if level.rmsDecibels > -47 { return true }
        guard let features = VoiceAnalyzer.analyze(samples) else { return false }
        return features.activityRatio * features.duration >= 0.4
            && features.voicedRatio * features.duration >= 0.3
    }
}
