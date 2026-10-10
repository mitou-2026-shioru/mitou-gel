import XCTest
@testable import HapticCore

final class VoicePipelineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tone(frequency: Double, amplitude: Double = 0.1, seconds: Double = 2) -> [Float] {
        (0..<Int(16_000 * seconds)).map { offset in
            Float(amplitude * sin(2 * .pi * frequency * Double(offset) / 16_000))
        }
    }

    func testTonePitchAndActivity() throws {
        let features = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200), measuredAt: now))
        XCTAssertEqual(try XCTUnwrap(features.medianPitchHz), 200, accuracy: 3)
        XCTAssertGreaterThan(features.voicedRatio, 0.95)
        XCTAssertEqual(features.activityRatio, 1)
        XCTAssertLessThan(features.pitchVariationSemitones, 0.1)
        XCTAssertTrue(features.hasVoiceEvidence)
    }

    func testPitchVariationDoesNotUseAbsolutePitchAsEmotion() throws {
        let lower = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 120), measuredAt: now))
        let higher = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 300), measuredAt: now))
        XCTAssertEqual(VoiceSignal(features: lower).haptic.stiffness,
                       VoiceSignal(features: higher).haptic.stiffness, accuracy: 0.02)
        let varied = try XCTUnwrap(VoiceAnalyzer.analyze(
            tone(frequency: 150, seconds: 1) + tone(frequency: 300, seconds: 1), measuredAt: now))
        XCTAssertGreaterThan(varied.pitchVariationSemitones, 4)
        XCTAssertGreaterThan(VoiceSignal(features: varied).haptic.stiffness,
                             VoiceSignal(features: lower).haptic.stiffness)
    }

    func testSilenceAndConstantSignalHaveNoVoiceEvidence() throws {
        for value: Float in [0, 0.2] {
            let features = try XCTUnwrap(VoiceAnalyzer.analyze(Array(repeating: value, count: 32_000)))
            XCTAssertFalse(features.hasVoiceEvidence)
            XCTAssertNil(features.medianPitchHz)
            XCTAssertEqual(VoiceSignal(features: features).haptic, .neutral)
        }
    }

    func testBroadbandNoiseDoesNotProducePitchEvidence() throws {
        var seed: UInt64 = 42
        let noise: [Float] = (0..<32_000).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5) * 0.2
        }
        let features = try XCTUnwrap(VoiceAnalyzer.analyze(noise))
        XCTAssertGreaterThan(features.activityRatio, 0.9)
        XCTAssertLessThan(features.voicedRatio, 0.15)
        XCTAssertEqual(VoiceSignal(features: features).haptic, .neutral)
    }

    func testPausesReduceContinuityAndRemainBounded() throws {
        let uninterrupted = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200)))
        let paused = try XCTUnwrap(VoiceAnalyzer.analyze(
            tone(frequency: 200, seconds: 1) + Array(repeating: 0, count: 16_000)))
        XCTAssertEqual(paused.pauseRatio, 0.5, accuracy: 0.03)
        XCTAssertLessThan(VoiceSignal(features: paused).haptic.temperature,
                          VoiceSignal(features: uninterrupted).haptic.temperature)
        XCTAssertTrue((0...1).contains(VoiceSignal(features: paused).haptic.stiffness))
    }

    func testRelativeStrengthCanBeCalibrated() throws {
        let quiet = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200, amplitude: 0.03)))
        let loud = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200, amplitude: 0.3)))
        XCTAssertLessThan(VoiceSignal(features: quiet).haptic.stiffness,
                          VoiceSignal(features: loud).haptic.stiffness)
        XCTAssertEqual(VoiceSignal(features: quiet, referenceDecibels: quiet.rmsDecibels).relativeStrength, 0.5)
        XCTAssertEqual(VoiceSignal(features: loud, referenceDecibels: loud.rmsDecibels).relativeStrength, 0.5)
    }

    func testInvalidAudioIsRejected() {
        XCTAssertNil(VoiceAnalyzer.analyze([]))
        XCTAssertNil(VoiceAnalyzer.analyze(Array(repeating: 0, count: 7_999)))
        XCTAssertNil(VoiceAnalyzer.analyze(Array(repeating: 0, count: 160_001)))
        XCTAssertNil(VoiceAnalyzer.analyze(tone(frequency: 200), sampleRate: 44_100))
        for value: Float in [.nan, .infinity, 2] {
            XCTAssertNil(VoiceAnalyzer.analyze(Array(repeating: value, count: 32_000)))
        }
    }

    func testCombinedUsesTextForTemperatureAndBothForStiffness() throws {
        let features = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200), measuredAt: now))
        let voice = VoiceSignal(features: features)
        let text = ConversationSignal(text: "安心", measuredAt: now)
        let state = ExpressionMapping.map(text: text, voice: voice, mode: .combined, now: now)
        XCTAssertEqual(state.haptic.temperature, text.haptic.temperature)
        XCTAssertEqual(state.haptic.stiffness, 0.35 * text.arousal + 0.65 * voice.haptic.stiffness)
        XCTAssertTrue(state.usesVoice)
        XCTAssertTrue(state.usesText)
    }

    func testVoiceOnlyDoesNotRequireTextAndTextOnlyIgnoresVoice() throws {
        let features = try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200), measuredAt: now))
        let voice = VoiceSignal(features: features)
        XCTAssertEqual(ExpressionMapping.map(text: nil, voice: voice, mode: .voice, now: now).haptic, voice.haptic)
        XCTAssertFalse(ExpressionMapping.map(text: nil, voice: voice, mode: .text, now: now).fresh)
        let unknown = ConversationSignal(text: "駅に着きました", measuredAt: now)
        XCTAssertEqual(ExpressionMapping.map(text: unknown, voice: voice, mode: .text, now: now).haptic, .neutral)
    }

    func testStaleFutureAndSilenceDoNotKeepVoiceOutputAlive() throws {
        let voice = VoiceSignal(features: try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200), measuredAt: now)))
        XCTAssertFalse(ExpressionMapping.map(text: nil, voice: voice, mode: .voice,
                                              now: now.addingTimeInterval(7)).fresh)
        XCTAssertFalse(ExpressionMapping.map(text: nil, voice: voice, mode: .voice,
                                              now: now.addingTimeInterval(-1)).fresh)
        let silence = VoiceSignal(features: try XCTUnwrap(VoiceAnalyzer.analyze(Array(repeating: 0, count: 32_000))))
        XCTAssertFalse(ExpressionMapping.map(text: nil, voice: silence, mode: .voice).fresh)
        let text = ConversationSignal(text: "安心", measuredAt: now)
        XCTAssertEqual(ExpressionMapping.map(text: text, voice: voice, mode: .combined,
                                              now: now.addingTimeInterval(7)).haptic, text.haptic)
    }

    func testCombinedFallsBackToVoiceForUnknownStaleAndFutureText() throws {
        let voice = VoiceSignal(features: try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200), measuredAt: now)))
        let texts = [ConversationSignal(text: "駅に着きました", measuredAt: now),
                     ConversationSignal(text: "安心", measuredAt: now.addingTimeInterval(-31)),
                     ConversationSignal(text: "安心", measuredAt: now.addingTimeInterval(1))]
        for text in texts {
            let state = ExpressionMapping.map(text: text, voice: voice, mode: .combined, now: now)
            XCTAssertEqual(state.haptic, voice.haptic)
            XCTAssertTrue(state.fresh)
            XCTAssertTrue(state.usesVoice)
        }
        let text = ConversationSignal(text: "安心", measuredAt: now)
        let state = ExpressionMapping.map(text: text, voice: voice, mode: .voice, now: now)
        XCTAssertEqual(state.haptic, voice.haptic)
        XCTAssertFalse(state.usesText)
    }

    func testFreshnessLimitsDoNotDependOnTheOutputWindow() throws {
        let voice = VoiceSignal(features: try XCTUnwrap(VoiceAnalyzer.analyze(tone(frequency: 200), measuredAt: now)))
        XCTAssertTrue(ExpressionMapping.map(text: nil, voice: voice, mode: .voice,
                                             now: now.addingTimeInterval(6)).fresh)
        let expiredVoice = ExpressionMapping.map(text: nil, voice: voice, mode: .voice,
                                                 now: now.addingTimeInterval(6.001))
        XCTAssertFalse(expiredVoice.fresh)
        XCTAssertEqual(expiredVoice.haptic, .neutral)
        let text = ConversationSignal(text: "安心", measuredAt: now)
        XCTAssertTrue(ExpressionMapping.map(text: text, voice: nil, mode: .text,
                                             now: now.addingTimeInterval(30)).fresh)
        XCTAssertFalse(ExpressionMapping.map(text: text, voice: nil, mode: .text,
                                              now: now.addingTimeInterval(30.001)).fresh)
    }
}
