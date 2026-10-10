import CoreML
import XCTest
@testable import HapticCore

final class AudioEmotionTests: XCTestCase {
    private struct Fixture: Decodable {
        let features: [String: Double]
        let probabilities: [String: Double]
    }

    private func samples() -> [Float] {
        (0..<32_000).map { index in
            let time = Double(index) / 16_000
            let envelope = index < 4_000 || index >= 28_000 ? 0 : 0.18 + 0.08 * sin(2 * .pi * 0.8 * time)
            let value = envelope * (sin(2 * .pi * (140 * time + 20 * time * time))
                + 0.22 * sin(2 * .pi * (310 * time + 30 * time * time)))
            return Float(Int(value * 32_768)) / 32_768
        }
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "circumplex-features", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testAllModelFeaturesMatchPythonReference() throws {
        let expected = try fixture()
        let actual = try XCTUnwrap(CircumplexAudioFeatures.analyze(samples()))
        XCTAssertEqual(expected.features.count, 68)
        for (name, value) in expected.features {
            XCTAssertEqual(try XCTUnwrap(actual[name], name), value, accuracy: max(0.002, abs(value) * 0.001), name)
        }
    }

    func testFeatureExtractionRejectsInvalidAudio() {
        XCTAssertNil(CircumplexAudioFeatures.analyze([]))
        XCTAssertNil(CircumplexAudioFeatures.analyze(Array(repeating: 0, count: 7_999)))
        XCTAssertNil(CircumplexAudioFeatures.analyze(Array(repeating: 0, count: 128_001)))
        XCTAssertNil(CircumplexAudioFeatures.analyze(Array(repeating: .nan, count: 32_000)))
        XCTAssertNil(CircumplexAudioFeatures.analyze(samples(), sampleRate: 48_000))
    }

    func testSilentFeaturesAreFinite() throws {
        let features = try XCTUnwrap(CircumplexAudioFeatures.analyze(Array(repeating: 0, count: 32_000)))
        XCTAssertTrue(features.values.allSatisfy(\.isFinite))
        XCTAssertEqual(features["voiced_ratio"], 0)
        XCTAssertEqual(features["pitch_active_p50"], 0)
    }

    func testCoreMLAudioClassificationMatchesPython() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("iOS/Models")
        let compiled = try await MLModel.compileModel(at: directory.appendingPathComponent("VoiceCircumplex.mlmodel"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        let model = try AudioEmotionModel(modelURL: compiled, metadataURL: directory.appendingPathComponent("VoiceCircumplex.json"))
        let prediction = try await model.classify(samples(), measuredAt: Date(timeIntervalSince1970: 100))
        let result = try XCTUnwrap(prediction)
        let expected = try fixture()
        XCTAssertEqual(result.probabilities.count, 6)
        XCTAssertEqual(result.probabilities.values.reduce(0, +), 1, accuracy: 0.0001)
        for (label, probability) in expected.probabilities {
            XCTAssertEqual(try XCTUnwrap(result.probabilities[label]), probability, accuracy: 0.001, label)
        }
        XCTAssertTrue((-1...1).contains(try XCTUnwrap(result.observation.dimensions[.valence])))
        XCTAssertTrue((-1...1).contains(try XCTUnwrap(result.observation.dimensions[.arousal])))
        let silence = try await model.classify(Array(repeating: 0, count: 32_000), measuredAt: Date())
        XCTAssertNil(silence)
    }
}
