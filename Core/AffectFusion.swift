import Foundation

public enum AffectDimension: String, CaseIterable, Hashable, Sendable {
    case valence
    case arousal
}

public struct AffectObservation: Sendable {
    public let source: String
    public let measuredAt: Date
    public let dimensions: [AffectDimension: Double]
    public let confidence: Double

    public init?(source: String, measuredAt: Date, dimensions: [AffectDimension: Double], confidence: Double) {
        guard !source.isEmpty, measuredAt.timeIntervalSince1970.isFinite, !dimensions.isEmpty,
              dimensions.values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
              confidence.isFinite, (0...1).contains(confidence) else { return nil }
        self.source = source
        self.measuredAt = measuredAt
        self.dimensions = dimensions
        self.confidence = confidence
    }
}

public struct AffectSourcePolicy: Sendable {
    public let reliability: [AffectDimension: Double]
    public let decaySeconds: Double
    public let freshnessSeconds: Double
    public let enabled: Bool

    public init(reliability: [AffectDimension: Double], decaySeconds: Double,
                freshnessSeconds: Double, enabled: Bool = true) {
        self.reliability = reliability
        self.decaySeconds = decaySeconds
        self.freshnessSeconds = freshnessSeconds
        self.enabled = enabled
    }

    fileprivate var usable: Bool {
        enabled && decaySeconds.isFinite && decaySeconds > 0
            && freshnessSeconds.isFinite && freshnessSeconds > 0
            && reliability.values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
    }
}

public struct AffectState: Sendable {
    public let dimensions: [AffectDimension: Double]
    public let confidence: [AffectDimension: Double]
    public let disagreement: [AffectDimension: Double]
    public let contributions: [String: Double]
    public let observationCount: Int

    public var valence: Double { dimensions[.valence] ?? 0 }
    public var arousal: Double { dimensions[.arousal] ?? 0 }

}

public enum AffectFusion {
    public static let voiceSource = "audio.prosody"
    public static let textSource = "text.rules"
    public static let modelSource = "audio.model"
    public static let policies: [String: AffectSourcePolicy] = [
        voiceSource: AffectSourcePolicy(reliability: [.valence: 0, .arousal: 1],
                                        decaySeconds: 8, freshnessSeconds: 6),
        textSource: AffectSourcePolicy(reliability: [.valence: 1, .arousal: 0.5],
                                       decaySeconds: 20, freshnessSeconds: 30),
        modelSource: AffectSourcePolicy(reliability: [.valence: 0.8, .arousal: 1],
                                        decaySeconds: 8, freshnessSeconds: 6)
    ]

    public static func fuse(_ observations: [AffectObservation], now: Date,
                            policies: [String: AffectSourcePolicy] = AffectFusion.policies) -> AffectState {
        let fresh = observations.filter { observation in
            guard let policy = policies[observation.source], policy.usable, observation.confidence > 0 else { return false }
            return (0...policy.freshnessSeconds).contains(now.timeIntervalSince(observation.measuredAt))
                && observation.dimensions.contains { (policy.reliability[$0.key] ?? 0) > 0 }
        }
        var dimensions: [AffectDimension: Double] = [:]
        var confidence: [AffectDimension: Double] = [:]
        var disagreement: [AffectDimension: Double] = [:]
        var contributions: [String: Double] = [:]
        for dimension in AffectDimension.allCases {
            let entries = fresh.compactMap { observation -> (source: String, value: Double, weight: Double)? in
                guard let value = observation.dimensions[dimension], let policy = policies[observation.source] else { return nil }
                let age = now.timeIntervalSince(observation.measuredAt)
                let weight = (policy.reliability[dimension] ?? 0) * observation.confidence * exp(-age / policy.decaySeconds)
                return weight > 0.0001 ? (observation.source, value, weight) : nil
            }
            func gate(_ residual: Double) -> Double { exp(-residual * residual / (2 * 0.5 * 0.5)) }
            func mean(center: Double?) -> Double {
                var numerator = 0.0
                var denominator = 0.15
                for entry in entries {
                    let weight = entry.weight * (center.map { gate(entry.value - $0) } ?? 1)
                    numerator += weight * entry.value
                    denominator += weight
                }
                return numerator / denominator
            }
            var value = mean(center: nil)
            for _ in 0..<3 { value = mean(center: value) }
            let total = entries.reduce(0) { $0 + $1.weight }
            let variance = total > 0 ? entries.reduce(0) { $0 + $1.weight * pow($1.value - value, 2) } / total : 0
            let difference = max(0, min(1, sqrt(variance) / 0.8))
            var evidence = 0.0
            for entry in entries {
                let weight = entry.weight * gate(entry.value - value)
                evidence += weight
                contributions[entry.source, default: 0] += weight
            }
            dimensions[dimension] = value
            disagreement[dimension] = difference
            confidence[dimension] = max(0, min(1, evidence / (evidence + 0.6) * (1 - difference)))
        }
        let total = contributions.values.reduce(0, +)
        if total > 0 { contributions = contributions.mapValues { $0 / total } }
        return AffectState(dimensions: dimensions, confidence: confidence, disagreement: disagreement,
                           contributions: contributions, observationCount: fresh.count)
    }
}

public struct AffectBuffer: Sendable {
    public private(set) var observations: [AffectObservation] = []
    public let policies: [String: AffectSourcePolicy]

    public init(policies: [String: AffectSourcePolicy] = AffectFusion.policies) { self.policies = policies }

    @discardableResult
    public mutating func ingest(_ observation: AffectObservation, now: Date = Date()) -> Bool {
        prune(now: now)
        guard let policy = policies[observation.source], policy.usable, observation.confidence > 0,
              (0...policy.freshnessSeconds).contains(now.timeIntervalSince(observation.measuredAt)),
              observation.dimensions.contains(where: { (policy.reliability[$0.key] ?? 0) > 0 }) else { return false }
        let latest = observations.filter { $0.source == observation.source }.map(\.measuredAt).max()
        guard latest.map({ observation.measuredAt >= $0 }) ?? true else { return false }
        observations.removeAll { $0.source == observation.source && $0.measuredAt == observation.measuredAt }
        observations.append(observation)
        if observations.count > 64 { observations.removeFirst(observations.count - 64) }
        return true
    }

    public mutating func prune(now: Date) {
        observations.removeAll {
            guard let policy = policies[$0.source], policy.usable else { return true }
            return !(0...policy.freshnessSeconds).contains(now.timeIntervalSince($0.measuredAt))
        }
    }

    public mutating func remove(source: String) { observations.removeAll { $0.source == source } }
    public mutating func reset() { observations.removeAll() }
}

public enum AffectProjection {
    public static func observation(probabilities: [String: Double],
                                   prototypes: [String: [AffectDimension: Double]],
                                   source: String = AffectFusion.modelSource,
                                   measuredAt: Date) -> AffectObservation? {
        guard !probabilities.isEmpty,
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        let total = probabilities.values.reduce(0, +)
        guard total > 0 else { return nil }
        var sums: [AffectDimension: Double] = [:]
        var weights: [AffectDimension: Double] = [:]
        var covered = 0.0
        for (label, probability) in probabilities where probability > 0 {
            guard let point = prototypes[label], !point.isEmpty,
                  point.values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { continue }
            covered += probability
            for (dimension, value) in point {
                sums[dimension, default: 0] += probability * value
                weights[dimension, default: 0] += probability
            }
        }
        guard covered > 0 else { return nil }
        let dimensions = sums.map { dimension, sum in (dimension, sum / (weights[dimension] ?? 1)) }
        let entropy = probabilities.values.filter { $0 > 0 }.reduce(0) { result, probability in
            let normalized = probability / total
            return result - normalized * log(normalized)
        }
        let certainty = probabilities.count > 1 ? max(0, min(1, 1 - entropy / log(Double(probabilities.count)))) : 1
        return AffectObservation(source: source, measuredAt: measuredAt,
                                 dimensions: Dictionary(uniqueKeysWithValues: dimensions),
                                 confidence: certainty * covered / total)
    }
}
