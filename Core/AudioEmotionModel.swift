import CoreML
import Foundation

public struct AudioEmotionResult: Sendable {
    public let probabilities: [String: Double]
    public let observation: AffectObservation
    public var topLabel: String { probabilities.max { $0.value < $1.value }?.key ?? "unknown" }
    public var maximumProbability: Double { probabilities.values.max() ?? 0 }
}

public actor AudioEmotionModel {
    private struct Metadata: Decodable {
        let features: [String]
        let classes: [String]
        let prototypes: [String: [String: Double]]
    }

    private let model: MLModel
    private let metadata: Metadata

    public init(modelURL: URL, metadataURL: URL) throws {
        metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.features.count == 68, Set(metadata.features).count == 68,
              metadata.classes.count == 6, Set(metadata.classes).count == 6 else { throw AudioEmotionFailure.invalidModel }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        guard model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.shape == [68],
              model.modelDescription.outputDescriptionsByName["probabilities"]?.multiArrayConstraint?.shape == [6] else {
            throw AudioEmotionFailure.invalidModel
        }
    }

    public func classify(_ samples: [Float], measuredAt: Date) throws -> AudioEmotionResult? {
        guard VoiceAnalyzer.analyze(samples, measuredAt: measuredAt)?.hasVoiceEvidence == true else { return nil }
        guard let features = CircumplexAudioFeatures.analyze(samples) else { throw AudioEmotionFailure.invalidAudio }
        let input = try MLMultiArray(shape: [68], dataType: .float32)
        for (index, name) in metadata.features.enumerated() {
            guard let value = features[name], value.isFinite else { throw AudioEmotionFailure.invalidAudio }
            input[index] = NSNumber(value: value)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["features": input])
        let output = try model.prediction(from: provider)
        guard let values = output.featureValue(for: "probabilities")?.multiArrayValue, values.count == 6 else {
            throw AudioEmotionFailure.invalidModel
        }
        let probabilities = Dictionary(uniqueKeysWithValues: metadata.classes.enumerated().map {
            ($0.element, values[$0.offset].doubleValue)
        })
        guard probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(probabilities.values.reduce(0, +) - 1) < 0.001 else { throw AudioEmotionFailure.invalidModel }
        let prototypes = metadata.prototypes.mapValues { point in
            Dictionary(uniqueKeysWithValues: point.compactMap { name, value in
                AffectDimension(rawValue: name).map { ($0, value) }
            })
        }
        guard let observation = AffectProjection.observation(probabilities: probabilities,
            prototypes: prototypes, measuredAt: measuredAt) else { throw AudioEmotionFailure.invalidModel }
        return AudioEmotionResult(probabilities: probabilities, observation: observation)
    }
}

private enum AudioEmotionFailure: LocalizedError {
    case invalidModel
    case invalidAudio
    var errorDescription: String? {
        switch self {
        case .invalidModel: "音声分類モデルの構造または出力が不正です。"
        case .invalidAudio: "音声分類用の特徴を取得できません。"
        }
    }
}
