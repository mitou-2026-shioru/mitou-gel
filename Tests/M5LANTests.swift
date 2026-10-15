import Foundation
import XCTest
@testable import HapticCore

final class M5LANTests: XCTestCase {
    func testCommandsAndResponsesMatchActualFirmware() throws {
        struct Fixture: Decodable {
            struct Transaction: Decodable { let request: String; let response: String }
            let initial: String
            let transactions: [Transaction]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "m5-lan-v3", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let initial = try M5LANProtocol.state(hex(fixture.initial))
        XCTAssertEqual(initial.temperature, 23.5)
        XCTAssertTrue(initial.ready)
        XCTAssertFalse(initial.remote)
        let operations: [M5LANProtocol.Operation] = [.hello, .target, .pump, .heater, .ping, .stop, .release]
        let scalars = [0.0, 0.5, 0.5, 1, 0, 0, 0]
        var states: [M5LANState] = []
        for (index, transaction) in fixture.transactions.enumerated() {
            let number = UInt32(index + 1)
            let encoded = try M5LANProtocol.command(operations[index], session: 0x11223344, sequence: number, value: scalars[index])
            XCTAssertEqual(String(data: encoded, encoding: .utf8), transaction.request)
            let state = try M5LANProtocol.response(hex(transaction.response), session: 0x11223344, sequence: number)
            XCTAssertTrue(state.isNewer(than: states.last ?? initial))
            states.append(state)
        }
        XCTAssertEqual(states[1].target, 0.5)
        XCTAssertEqual(M5LANProtocol.targetCelsius(states[1].target), 37.5)
        XCTAssertEqual(states[2].pump, 0.38)
        XCTAssertTrue(states[3].heater)
        XCTAssertTrue(states[3].heating)
        XCTAssertEqual(states[3].voltage, 5)
        XCTAssertFalse(states[5].heater)
        XCTAssertEqual(states[5].pump, 0)
        XCTAssertFalse(states[6].remote)
    }

    func testValidationAndPumpBoundaries() throws {
        XCTAssertTrue(M5LANProtocol.validPIN("00123456"))
        for pin in ["123456", "１２３４５６７８", "1234567a", "123456789"] { XCTAssertFalse(M5LANProtocol.validPIN(pin)) }
        XCTAssertNotNil(M5LANProtocol.url("http://m5-control.local"))
        XCTAssertNil(M5LANProtocol.url("https://m5-control.local"))
        XCTAssertNil(M5LANProtocol.url("http://m5-control.local:8080"))
        for (value, applied) in [(0.19, 0.0), (0.1901, 0.38), (0.545, 0.38), (0.5451, 0.71), (0.855, 0.71), (0.8551, 1.0)] {
            XCTAssertEqual(M5LANProtocol.appliedPump(value), applied)
        }
        for value in [Double.nan, .infinity, -1, 2] {
            XCTAssertThrowsError(try M5LANProtocol.command(.target, session: 1, sequence: 1, value: value))
        }
        XCTAssertThrowsError(try M5LANProtocol.command(.heater, session: 1, sequence: 1, value: 0.5))
        XCTAssertThrowsError(try M5LANProtocol.command(.ping, session: 1, sequence: 1, value: 1))
    }

    func testInvalidFramesMismatchedACKAndWrappingCounter() throws {
        var data = stateData(counter: UInt32.max)
        let before = try M5LANProtocol.state(data)
        let after = try M5LANProtocol.state(stateData(counter: 0))
        XCTAssertTrue(after.isNewer(than: before))
        XCTAssertFalse(before.isNewer(than: after))
        XCTAssertFalse(before.isNewer(than: before))
        data[1] = 2
        XCTAssertThrowsError(try M5LANProtocol.state(data))
        XCTAssertThrowsError(try M5LANProtocol.state(Data(repeating: 0, count: 19)))
        let response = ackData(session: 123, sequence: 7) + stateData()
        XCTAssertThrowsError(try M5LANProtocol.response(response, session: 124, sequence: 7))
        XCTAssertThrowsError(try M5LANProtocol.response(response, session: 123, sequence: 8))
        var missing = stateData()
        missing[8] = 0; missing[9] = 0x80; missing[12] = 0xff; missing[13] = 0xff
        let state = try M5LANProtocol.state(missing)
        XCTAssertNil(state.temperature)
        XCTAssertNil(state.voltage)
    }

    @MainActor func testAuthenticationFailureSendsNoCommands() async {
        let firmware = FakeM5()
        let client = client(firmware, pin: "00000000")
        let connected = await client.connect()
        XCTAssertFalse(connected)
        XCTAssertFalse(client.outputEnabled)
        let commands = await firmware.commands
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(client.message.contains("PIN"))
    }

    @MainActor func testStartHeartbeatQuantizationAndRelease() async throws {
        let firmware = FakeM5()
        let client = client(firmware)
        let connected = await client.connect()
        XCTAssertTrue(connected)
        let before = await firmware.commands
        XCTAssertTrue(before.isEmpty, "A connection is read-only; it must not start physical output.")
        let desired = HapticState(temperature: 0.5, stiffness: 0.5)
        let started = await client.startOutput(desired)
        XCTAssertTrue(started)
        XCTAssertEqual(client.state?.pump, 0.38)
        let updated = await client.updateOutput(desired)
        XCTAssertTrue(updated)
        try await Task.sleep(for: .milliseconds(1_050))
        let runningCommands = await firmware.commands
        XCTAssertGreaterThanOrEqual(runningCommands.filter { $0 == .ping }.count, 2)
        XCTAssertEqual(runningCommands.filter { $0 == .heater }.count, 1)
        XCTAssertTrue(client.outputEnabled)
        await client.stop()
        XCTAssertFalse(client.outputEnabled)
        XCTAssertFalse(client.state?.remote ?? true)
        XCTAssertEqual(client.state?.pump, 0)
        XCTAssertEqual(client.state?.heater, false)
        let count = await firmware.commands.count
        try await Task.sleep(for: .milliseconds(500))
        let stoppedCommands = await firmware.commands
        XCTAssertEqual(stoppedCommands.count, count, "STOP must end the heartbeat.")
    }

    @MainActor func testStopInvalidatesDelayedStartWithoutEnablingHeater() async throws {
        let firmware = FakeM5()
        await firmware.holdTargetResponse()
        let client = client(firmware)
        _ = await client.connect()
        let start = Task { await client.startOutput(HapticState(temperature: 0.5, stiffness: 1)) }
        await firmware.waitForTarget()
        await client.stop()
        await firmware.releaseTargetResponse()
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertFalse(client.outputEnabled)
        XCTAssertEqual(client.state?.pump, 0)
        let commands = await firmware.commands
        XCTAssertFalse(commands.contains(.heater))
        XCTAssertFalse(commands.contains(.pump))
        XCTAssertEqual(Array(commands.suffix(2)), [.stop, .release])
    }

    @MainActor func testLocalStopDoesNotAutomaticallyReclaimSession() async throws {
        let firmware = FakeM5()
        let client = client(firmware)
        var lost = false
        client.onOutputLost = { _ in lost = true }
        _ = await client.connect()
        _ = await client.startOutput(HapticState(temperature: 0.5, stiffness: 1))
        await firmware.localStop()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(lost)
        XCTAssertFalse(client.outputEnabled)
        let updated = await client.updateOutput(HapticState(temperature: 1, stiffness: 1))
        XCTAssertFalse(updated)
        let commands = await firmware.commands
        XCTAssertEqual(commands.filter { $0 == .hello }.count, 1)
    }

    @MainActor func testPartialFailureStopsPumpAndDoesNotRetryStart() async {
        let firmware = FakeM5()
        await firmware.failHeaterStart()
        let client = client(firmware)
        _ = await client.connect()
        let started = await client.startOutput(HapticState(temperature: 0.5, stiffness: 1))
        XCTAssertFalse(started)
        XCTAssertFalse(client.outputEnabled)
        XCTAssertEqual(client.state?.pump, 0)
        XCTAssertEqual(client.state?.heater, false)
        let commands = await firmware.commands
        XCTAssertEqual(Array(commands.suffix(2)), [.stop, .release])
        XCTAssertEqual(commands.filter { $0 == .heater }.count, 1)
    }

    @MainActor func testForeignOwnerIsNeverStoppedOrTakenOver() async {
        let firmware = FakeM5()
        await firmware.setForeignOwner()
        let client = client(firmware)
        _ = await client.connect()
        let started = await client.startOutput(.neutral)
        XCTAssertFalse(started)
        await client.stop()
        let commands = await firmware.commands
        XCTAssertTrue(commands.isEmpty)
    }

    @MainActor func testCompetingHelloDoesNotSendGlobalStopToOtherController() async {
        let firmware = FakeM5()
        let client = client(firmware)
        _ = await client.connect()
        // Another controller acquires ownership after our GET, before HELLO.
        await firmware.setForeignOwner()
        let started = await client.startOutput(.neutral)
        XCTAssertFalse(started)
        let commands = await firmware.commands
        XCTAssertEqual(commands, [.hello])
        XCTAssertEqual(client.state?.session, 999)
        XCTAssertEqual(client.state?.pump, 1)
        XCTAssertTrue(client.state?.heater ?? false)
    }

    @MainActor private func client(_ firmware: FakeM5, pin: String = "00123456") -> M5LANClient {
        let client = M5LANClient { try await firmware.request($0) }
        XCTAssertTrue(client.configure(address: "http://m5-control.local", pin: pin))
        return client
    }
}

private actor FakeM5 {
    var commands: [M5LANProtocol.Operation] = []
    private var session: UInt32 = 0
    private var sequence: UInt32 = 0
    private var counter: UInt32 = 0
    private var target: UInt16 = 10_000
    private var pump: UInt8 = 0
    private var heater = false
    private var rejectHeater = false
    private var holdTarget = false
    private var targetSeen = false
    private var targetWaiter: CheckedContinuation<Void, Never>?
    private var targetResponse: CheckedContinuation<Void, Never>?

    func holdTargetResponse() { holdTarget = true }
    func failHeaterStart() { rejectHeater = true }
    func setForeignOwner() { session = 999; heater = true; pump = 100 }
    func localStop() { session = 0; heater = false; pump = 0 }
    func waitForTarget() async {
        if targetSeen { return }
        await withCheckedContinuation { targetWaiter = $0 }
    }
    func releaseTargetResponse() { targetResponse?.resume(); targetResponse = nil }

    func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func response(_ data: Data, _ code: Int = 200) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        guard request.value(forHTTPHeaderField: "X-M5-Key") == "00123456" else { return response(Data(), 401) }
        if url.path == "/api/state", request.httpMethod == "GET" { return response(snapshot()) }
        guard url.path == "/api/command", request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Content-Type") == "text/plain",
              let body = request.httpBody, body.count == 32,
              let text = String(data: body, encoding: .utf8) else { return response(Data(), 400) }
        let bytes = Array(hex(text))
        guard let op = M5LANProtocol.Operation(rawValue: bytes[2]) else { return response(Data(), 400) }
        commands.append(op)
        let token = number(bytes, 4), seq = number(bytes, 8)
        let scalar = UInt16(bytes[12]) | UInt16(bytes[13]) << 8
        var error: UInt8 = 0
        if op == .stop {
            pump = 0; heater = false
            if token == session, seq > sequence { sequence = seq }
        } else if op == .hello {
            if session != 0, session != token { error = 3 }
            else { session = token; sequence = seq; pump = 0; heater = false }
        } else if token != session || session == 0 { error = 5 }
        else if seq <= sequence { error = 4 }
        else {
            sequence = seq
            switch op {
            case .target: target = scalar
            case .pump: pump = scalar <= 1_900 ? 0 : scalar <= 5_450 ? 38 : scalar <= 8_550 ? 71 : 100
            case .heater: if rejectHeater { error = 7 } else { heater = scalar == 10_000 }
            case .release: session = 0; pump = 0; heater = false
            default: break
            }
        }
        let result = ackData(session: token, sequence: seq, error: error) + snapshot()
        if op == .target, holdTarget {
            targetSeen = true; targetWaiter?.resume(); targetWaiter = nil
            await withCheckedContinuation { targetResponse = $0 }
        }
        return response(result)
    }

    private func snapshot() -> Data {
        counter &+= 1
        return stateData(counter: counter, session: session, target: target, pump: pump, heater: heater)
    }
}

private func hex(_ text: String) -> Data {
    let bytes = Array(text.utf8)
    return Data(stride(from: 0, to: bytes.count, by: 2).map { UInt8(String(bytes: bytes[$0..<($0 + 2)], encoding: .utf8)!, radix: 16)! })
}

private func number(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
}

private func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
    for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
}

private func ackData(session: UInt32, sequence: UInt32, error: UInt8 = 0) -> Data {
    var bytes: [UInt8] = [0x4d, 3, 0x81, error] + Array(repeating: 0, count: 8)
    put(session, into: &bytes, at: 4); put(sequence, into: &bytes, at: 8)
    return Data(bytes)
}

private func stateData(counter: UInt32 = 1, session: UInt32 = 0, target: UInt16 = 10_000,
                       pump: UInt8 = 0, heater: Bool = false) -> Data {
    let flags: UInt8 = 8 | (session == 0 ? 0 : 1) | (heater ? 6 : 0)
    var bytes: [UInt8] = [0x4d, 3, 0x80, flags, 0, 0, 0, 0, 0x2e, 0x09,
                          UInt8(truncatingIfNeeded: target), UInt8(target >> 8), 0x88, 0x13, pump, 0, 0, 0, 0, 0]
    put(session, into: &bytes, at: 4); put(counter, into: &bytes, at: 16)
    return Data(bytes)
}
