import XCTest
@testable import HapticCore

final class ConversationTests: XCTestCase {
    func testWarmCalmAndTenseWordsProduceDifferentVectors() {
        let calm = ConversationSignal(text: "ありがとう。安心してリラックスできた")
        let tense = ConversationSignal(text: "不安で緊張する。怖い")
        XCTAssertGreaterThan(calm.haptic.temperature, tense.haptic.temperature)
        XCTAssertLessThan(calm.haptic.stiffness, tense.haptic.stiffness)
    }

    func testUnknownWordsDoNotInventAnEmotion() {
        let signal = ConversationSignal(text: "駅まで歩いています")
        XCTAssertTrue(signal.evidence.isEmpty)
        XCTAssertEqual(signal.haptic, .neutral)
    }

    func testNegationAndBoundedText() {
        XCTAssertGreaterThan(ConversationSignal(text: "不安じゃない").valence,
                             ConversationSignal(text: "不安").valence)
        XCTAssertEqual(ConversationSignal(text: String(repeating: "あ", count: 2_000)).text.count, 1_000)
        XCTAssertLessThan(ConversationSignal(text: "緊張していない").arousal,
                          ConversationSignal(text: "緊張している").arousal)
        XCTAssertLessThan(ConversationSignal(text: "落ち着かない").valence,
                          ConversationSignal(text: "落ち着いた").valence)
    }

    func testCadenceDoesNotAccumulateWorkTimeOrBurstAfterMissedTicks() {
        let start = ContinuousClock().now
        var cadence = HapticCadence(start: start)
        cadence.advance(past: start + .milliseconds(300))
        XCTAssertEqual(start.duration(to: cadence.deadline), .seconds(2))
        cadence.advance(past: start + .milliseconds(2_700))
        XCTAssertEqual(start.duration(to: cadence.deadline), .seconds(4))
        cadence.advance(past: start + .seconds(10))
        XCTAssertEqual(start.duration(to: cadence.deadline), .seconds(12))
    }

    func testWindowBoundsInvalidDurationsAndOldFrames() {
        let now = Date()
        var window = HapticWindow()
        window.append(HapticFrame(date: now.addingTimeInterval(-121), state: .neutral), now: now)
        XCTAssertTrue(window.frames.isEmpty)
        window.append(HapticFrame(date: now, state: HapticState(temperature: 2, stiffness: -1)), now: now)
        XCTAssertEqual(window.mean(seconds: 10, now: now), HapticState(temperature: 1, stiffness: 0))
        XCTAssertNil(window.mean(seconds: .infinity, now: now))
        XCTAssertNil(window.mean(seconds: .nan, now: now))
    }

    func testWindowAveragesOnlyRecentVectorsAndRejectsReorderedFrames() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var window = HapticWindow()
        window.append(HapticFrame(date: now.addingTimeInterval(-20), state: HapticState(temperature: 0, stiffness: 1)), now: now)
        window.append(HapticFrame(date: now.addingTimeInterval(-4), state: HapticState(temperature: 0.4, stiffness: 0.2)), now: now)
        window.append(HapticFrame(date: now, state: HapticState(temperature: 0.8, stiffness: 0.4)), now: now)
        window.append(HapticFrame(date: now.addingTimeInterval(-1), state: .neutral), now: now)
        window.append(HapticFrame(date: now.addingTimeInterval(1), state: .neutral), now: now)
        XCTAssertEqual(window.frames.count, 3)
        XCTAssertEqual(window.mean(seconds: 10, now: now)?.temperature ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(window.mean(seconds: 10, now: now)?.stiffness ?? 0, 0.3, accuracy: 0.001)
        XCTAssertNil(window.mean(seconds: 0, now: now))
        XCTAssertNil(window.mean(seconds: 10, now: now.addingTimeInterval(40)))
        window.reset()
        XCTAssertTrue(window.frames.isEmpty)
    }
}
