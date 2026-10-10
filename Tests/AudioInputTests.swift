import XCTest
@testable import HapticCore

final class AudioInputTests: XCTestCase {
    private func tone(amplitude: Double, seconds: Double) -> [Float] {
        (0..<Int(16_000 * seconds)).map { offset in
            Float(amplitude * sin(2 * .pi * 200 * Double(offset) / 16_000))
        }
    }

    func testSilenceAndInvalidLevels() {
        XCTAssertEqual(AudioInputLevel.analyze(Array(repeating: 0, count: 100)), .silence)
        XCTAssertEqual(AudioInputLevel.silence.meter, 0)
        for samples: [Float] in [[], [.nan], [.infinity], [2]] {
            XCTAssertNil(AudioInputLevel.analyze(samples))
        }
    }

    func testDecibelsAndMeterExposeQuietAudioWithoutChangingSamples() throws {
        let level = try XCTUnwrap(AudioInputLevel.analyze(tone(amplitude: 0.004, seconds: 2)))
        XCTAssertEqual(level.rmsDecibels, 20 * log10(0.004 / sqrt(2)), accuracy: 0.01)
        XCTAssertEqual(level.peakDecibels, 20 * log10(0.004), accuracy: 0.01)
        XCTAssertGreaterThan(level.meter, 0.25)
        XCTAssertEqual(try XCTUnwrap(AudioInputLevel.analyze([1, -1])).meter, 1)
    }

    func testQuietVoicedSpeechPassesBelowPreviousAverageThreshold() throws {
        let samples = tone(amplitude: 0.004, seconds: 1) + Array(repeating: Float(0), count: 112_000)
        XCTAssertLessThan(try XCTUnwrap(AudioInputLevel.analyze(samples)).rmsDecibels, -47)
        XCTAssertTrue(SpeechAudioGate.accepts(samples))
    }

    func testOrdinaryLevelStillPasses() {
        XCTAssertTrue(SpeechAudioGate.accepts(tone(amplitude: 0.05, seconds: 8)))
    }

    func testGateRejectsSilenceWeakInputAndInvalidAudio() {
        for samples in [Array(repeating: Float(0), count: 128_000),
                        tone(amplitude: 0.000_1, seconds: 8),
                        Array(repeating: Float.nan, count: 128_000), [],
                        Array(repeating: Float(0), count: 128_001)] {
            XCTAssertFalse(SpeechAudioGate.accepts(samples))
        }
    }

    func testBriefQuietTransientDoesNotStartTranscription() {
        let samples = tone(amplitude: 0.004, seconds: 0.1) + Array(repeating: Float(0), count: 126_400)
        XCTAssertFalse(SpeechAudioGate.accepts(samples))
    }
}
