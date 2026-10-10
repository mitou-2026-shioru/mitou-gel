import XCTest
@testable import HapticCore

final class AffectFusionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 100)
    let flat: [String: AffectSourcePolicy] = [
        "voice": AffectSourcePolicy(reliability: [.valence: 1, .arousal: 1], decaySeconds: 8, freshnessSeconds: 32),
        "text": AffectSourcePolicy(reliability: [.valence: 1, .arousal: 1], decaySeconds: 8, freshnessSeconds: 32)
    ]

    private func observation(_ source: String, _ valence: Double, _ arousal: Double,
                             age: Double = 0, confidence: Double = 0.9) -> AffectObservation {
        AffectObservation(source: source, measuredAt: now.addingTimeInterval(-age),
                          dimensions: [.valence: valence, .arousal: arousal], confidence: confidence)!
    }

    func testEmptyAndExpiredStatesAreNeutral() {
        let empty = AffectFusion.fuse([], now: now, policies: flat)
        XCTAssertEqual(empty.valence, 0)
        XCTAssertEqual(empty.arousal, 0)
        XCTAssertEqual(empty.confidence[.valence], 0)
        let expired = AffectFusion.fuse([observation("voice", 0.8, 0.8, age: 33)], now: now, policies: flat)
        XCTAssertEqual(expired.observationCount, 0)
        XCTAssertEqual(expired.valence, 0)
    }

    func testConfidenceDecaysWithTimeAndFutureInputIsIgnored() {
        let immediate = AffectFusion.fuse([observation("voice", 0.8, 0.8)], now: now, policies: flat)
        let older = AffectFusion.fuse([observation("voice", 0.8, 0.8, age: 20)], now: now, policies: flat)
        XCTAssertLessThan(older.valence, immediate.valence)
        XCTAssertLessThan(older.confidence[.valence] ?? 0, immediate.confidence[.valence] ?? 0)
        XCTAssertEqual(AffectFusion.fuse([observation("voice", 0.8, 0.8, age: -1)], now: now, policies: flat).observationCount, 0)
    }

    func testConflictRaisesDisagreementAndReducesConfidence() {
        let agree = AffectFusion.fuse([observation("voice", 0.7, 0.5), observation("text", 0.7, 0.5)], now: now, policies: flat)
        let conflict = AffectFusion.fuse([observation("voice", -0.7, 0.5), observation("text", 0.7, 0.5)], now: now, policies: flat)
        XCTAssertEqual(conflict.valence, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(conflict.disagreement[.valence] ?? 0, 0.8)
        XCTAssertLessThan(conflict.confidence[.valence] ?? 0, agree.confidence[.valence] ?? 0)
        XCTAssertEqual(conflict.contributions.values.reduce(0, +), 1, accuracy: 0.0001)
    }

    func testSingleOutlierDoesNotOverrideSustainedEvidence() {
        let observations = [observation("voice", 0.5, 0.3, age: 3), observation("voice", 0.5, 0.3, age: 2),
                            observation("voice", 0.5, 0.3, age: 1), observation("voice", -0.9, -0.9)]
        let state = AffectFusion.fuse(observations, now: now, policies: flat)
        XCTAssertGreaterThan(state.valence, 0.2)
        XCTAssertGreaterThan(state.arousal, 0)
    }

    func testMissingDimensionDoesNotBecomeEvidenceForIt() throws {
        let voice = try XCTUnwrap(AffectObservation(source: AffectFusion.voiceSource, measuredAt: now,
                                                   dimensions: [.arousal: 0.8], confidence: 0.8))
        let state = AffectFusion.fuse([voice], now: now)
        XCTAssertEqual(state.valence, 0)
        XCTAssertEqual(state.confidence[.valence], 0)
        XCTAssertGreaterThan(state.arousal, 0)
    }

    func testInvalidAndDisabledObservationsCannotParticipate() {
        XCTAssertNil(AffectObservation(source: "voice", measuredAt: now, dimensions: [.arousal: .nan], confidence: 1))
        XCTAssertNil(AffectObservation(source: "voice", measuredAt: now, dimensions: [.arousal: 2], confidence: 1))
        XCTAssertNil(AffectObservation(source: "voice", measuredAt: now, dimensions: [.arousal: 0.5], confidence: .infinity))
        let policies = ["voice": AffectSourcePolicy(reliability: [.arousal: 1], decaySeconds: 0, freshnessSeconds: 6)]
        XCTAssertEqual(AffectFusion.fuse([observation("voice", 0.5, 0.5)], now: now, policies: policies).observationCount, 0)
        XCTAssertEqual(AffectFusion.fuse([observation("unknown", 0.5, 0.5)], now: now).observationCount, 0)
    }

    func testBufferIsBoundedOrderedAndReplacesCalibrationAtSameTime() {
        var buffer = AffectBuffer(policies: flat)
        XCTAssertTrue(buffer.ingest(observation("voice", 0.5, 0.5), now: now))
        XCTAssertFalse(buffer.ingest(observation("voice", 0.6, 0.6, age: 1), now: now))
        XCTAssertTrue(buffer.ingest(observation("voice", 0.2, 0.2), now: now))
        XCTAssertEqual(buffer.observations.count, 1)
        for index in 1...100 {
            let time = now.addingTimeInterval(Double(index) / 100)
            let value = AffectObservation(source: "voice", measuredAt: time, dimensions: [.arousal: 0.5], confidence: 0.8)!
            XCTAssertTrue(buffer.ingest(value, now: time))
        }
        XCTAssertEqual(buffer.observations.count, 64)
        buffer.prune(now: now.addingTimeInterval(40))
        XCTAssertTrue(buffer.observations.isEmpty)
    }

    func testProbabilityProjectionAndEntropyDoNotInventUnknownLabels() throws {
        let prototypes: [String: [AffectDimension: Double]] = ["joy": [.valence: 0.78, .arousal: 0.68],
                                                             "sadness": [.valence: -0.54, .arousal: -0.46]]
        let uniform = try XCTUnwrap(AffectProjection.observation(probabilities: ["joy": 0.5, "sadness": 0.5],
                                                                 prototypes: prototypes, measuredAt: now))
        XCTAssertEqual(uniform.dimensions[.valence] ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertEqual(uniform.dimensions[.arousal] ?? 0, 0.11, accuracy: 0.0001)
        XCTAssertEqual(uniform.confidence, 0, accuracy: 0.0001)
        let certain = try XCTUnwrap(AffectProjection.observation(probabilities: ["joy": 1, "sadness": 0],
                                                                 prototypes: prototypes, measuredAt: now))
        XCTAssertEqual(certain.confidence, 1)
        XCTAssertNil(AffectProjection.observation(probabilities: ["unknown": 1], prototypes: prototypes, measuredAt: now))
        XCTAssertNil(AffectProjection.observation(probabilities: ["joy": .nan], prototypes: prototypes, measuredAt: now))
        XCTAssertNil(AffectProjection.observation(probabilities: ["joy": -1], prototypes: prototypes, measuredAt: now))
    }
}
