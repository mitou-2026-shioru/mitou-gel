import XCTest
@testable import HapticCore

final class SignalPipelineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRollingMeanTrendAndCalibration() {
        var pipeline = SignalPipeline()
        for offset in [0.0, 10, 20] {
            pipeline.ingest(SensorReading(measuredAt: now.addingTimeInterval(offset - 20),
                                          heartRate: 70 + offset, source: .watch), now: now)
        }
        let state = pipeline.state(now: now)
        XCTAssertEqual(state.smoothedHeartRate, 80)
        XCTAssertEqual(state.trendPerMinute, 60, accuracy: 0.001)
        XCTAssertTrue(pipeline.calibrate(now: now))
        XCTAssertEqual(pipeline.baseline, 80)
    }

    func testStaleInputProducesNeutralAndCannotCalibrate() {
        var pipeline = SignalPipeline()
        for offset in [0.0, 1, 2] {
            pipeline.ingest(SensorReading(measuredAt: now.addingTimeInterval(offset - 50),
                                          heartRate: 100, source: .watch), now: now)
        }
        XCTAssertFalse(pipeline.state(now: now).fresh)
        XCTAssertEqual(HapticMapping().map(pipeline.state(now: now)), .neutral)
        XCTAssertFalse(pipeline.calibrate(now: now))
    }

    func testDuplicateAndOutOfOrderPacketsDoNotBiasHistory() {
        var pipeline = SignalPipeline()
        let reading = SensorReading(measuredAt: now, heartRate: 80, source: .watch)
        XCTAssertTrue(pipeline.ingest(reading, now: now))
        XCTAssertTrue(pipeline.ingest(reading, now: now))
        XCTAssertFalse(pipeline.ingest(SensorReading(measuredAt: now.addingTimeInterval(-1),
                                                     heartRate: 100, source: .watch), now: now))
        XCTAssertEqual(pipeline.points.count, 1)
    }

    func testInvalidAndFutureReadingsAreRejected() {
        var pipeline = SignalPipeline()
        for heartRate in [Double.nan, Double.infinity, 0, 300] {
            XCTAssertFalse(pipeline.ingest(SensorReading(measuredAt: now, heartRate: heartRate,
                                                         source: .watch), now: now))
        }
        XCTAssertFalse(pipeline.ingest(SensorReading(measuredAt: now.addingTimeInterval(30),
                                                     heartRate: 80, source: .watch), now: now))
    }

    func testHRVIsOnlyUsedWithinFiveMinutes() {
        var pipeline = SignalPipeline()
        pipeline.ingest(SensorReading(measuredAt: now, heartRate: 80, hrvMilliseconds: 45,
                                      hrvMeasuredAt: now.addingTimeInterval(-600), source: .watch), now: now)
        XCTAssertNil(pipeline.state(now: now).hrvMilliseconds)
    }

    func testSourceSwitchClearsHistory() {
        var pipeline = SignalPipeline()
        pipeline.ingest(SensorReading(measuredAt: now.addingTimeInterval(-2), heartRate: 120,
                                      source: .simulation), now: now)
        pipeline.ingest(SensorReading(measuredAt: now, heartRate: 65, source: .watch), now: now)
        XCTAssertEqual(pipeline.points.count, 1)
        XCTAssertEqual(pipeline.state(now: now).smoothedHeartRate, 65)
    }

    func testMappingIsBoundedAndCommandRoundTrips() throws {
        let state = HapticState(temperature: 4, stiffness: -2)
        XCTAssertEqual(state.temperature, 1)
        XCTAssertEqual(state.stiffness, 0)
        let command = DeviceCommand(state: state, enabled: true)
        XCTAssertEqual(try WireCodec.decode(DeviceCommand.self, from: WireCodec.encode(command)), command)
        XCTAssertEqual(command.ttlMilliseconds, 6_000)
        XCTAssertEqual(HapticState(temperature: .nan, stiffness: .infinity).temperature, 0.5)
    }

    func testLocalAddressValidation() {
        for address in ["http://192.168.4.1", "http://gel.local:8080", "http://localhost:8080", "http://10.0.0.2"] {
            XCTAssertNotNil(LocalDeviceAddress.url(from: address))
        }
        for address in ["http://example.com", "http://192.168.1.2.evil.com", "ftp://gel.local",
                        "http://user:pass@gel.local", "http://gel.local/path", "http://999.1.2.3"] {
            XCTAssertNil(LocalDeviceAddress.url(from: address))
        }
    }

    func testCSVQuotesCommasNewlinesAndQuotes() {
        XCTAssertEqual(CSV.row(["a,b", "c\"d", "line\nbreak"]), "\"a,b\",\"c\"\"d\",\"line\nbreak\"\n")
    }
}
