import Foundation

/// A single owner of the M5 LAN session. Every request is serialized; STOP
/// cancels an unfinished update and uses a higher sequence than its commands.
@MainActor
public final class M5LANClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public private(set) var state: M5LANState?
    public private(set) var connected = false
    public private(set) var outputEnabled = false
    public private(set) var busy = false
    public private(set) var message = "未接続"
    public var ownsSession: Bool { session != 0 && state?.remote == true && state?.session == session }
    public var onChange: (() -> Void)?
    public var onOutputLost: ((String) -> Void)?
    private let transport: Transport
    private let clock = ContinuousClock()
    private var address: URL?
    private var pin = ""
    private var session: UInt32 = 0
    private var sequence: UInt32 = 0
    private var generation = 0
    private var operation: Task<Void, Error>?
    private var heartbeat: Task<Void, Never>?
    private var lastFresh: ContinuousClock.Instant?

    public init(transport: @escaping Transport) { self.transport = transport }

    public func configure(address: String, pin: String) -> Bool {
        invalidate()
        state = nil; connected = false; session = 0; sequence = 0; lastFresh = nil
        self.address = M5LANProtocol.url(address)
        self.pin = pin
        if self.address == nil { message = M5LANError.invalidAddress.localizedDescription }
        else if !M5LANProtocol.validPIN(pin) { message = M5LANError.invalidPIN.localizedDescription }
        else { message = "接続確認待ち" }
        onChange?()
        return self.address != nil && M5LANProtocol.validPIN(pin)
    }

    public func connect() async -> Bool {
        guard address != nil, M5LANProtocol.validPIN(pin) else { return false }
        return await run { epoch in
            try await self.read(epoch)
            self.message = self.state?.remote == true ? "別の端末が操作中です" : "M5に接続しました"
        }
    }

    public func refresh() async {
        guard address != nil, M5LANProtocol.validPIN(pin), session == 0, !busy else { return }
        _ = await run { epoch in try await self.read(epoch) }
    }

    public func startOutput(_ desired: HapticState) async -> Bool {
        guard !busy, connected, let state else { return false }
        guard !state.remote else { message = M5LANError.rejected(3).localizedDescription; onChange?(); return false }
        guard state.ready, state.fault == 0 else {
            message = state.faultMessage ?? M5LANError.notReady.localizedDescription
            onChange?(); return false
        }
        session = UInt32.random(in: 1...UInt32.max)
        let token = session
        return await run { epoch in
            try await self.command(.hello, token: token, epoch: epoch)
            try self.checkOwnership(token)
            guard self.state?.heater == false, self.state?.pump == 0 else { throw M5LANError.invalidResponse }
            self.startHeartbeat(epoch: epoch, token: token)
            try await self.apply(desired, token: token, epoch: epoch, starting: true)
            self.outputEnabled = true
            self.message = "M5へ出力中"
        }
    }

    public func updateOutput(_ desired: HapticState) async -> Bool {
        guard !busy, outputEnabled, connected, session != 0 else { return false }
        let token = session
        return await run { epoch in
            try self.checkOwnership(token)
            try await self.apply(desired, token: token, epoch: epoch, starting: false)
        }
    }

    public func stop() async {
        let token = session
        let hadOwnership = ownsSession
        invalidate()
        session = 0
        // STOP is global in this firmware. Never send it after a rejected HELLO
        // or after a reply has shown that another client now owns the device.
        guard hadOwnership else { onChange?(); return }
        _ = await run(recover: false) { epoch in
            try await self.command(.stop, token: token, epoch: epoch)
            guard self.state?.heater == false, self.state?.pump == 0 else { throw M5LANError.invalidResponse }
            // A local B press or expiry may already have released the session.
            if self.state?.remote == true, self.state?.session == token {
                try await self.command(.release, token: token, epoch: epoch)
            }
            self.message = "M5の出力を停止しました"
        }
    }

    private func invalidate() {
        generation += 1
        operation?.cancel(); operation = nil
        heartbeat?.cancel(); heartbeat = nil
        busy = false; outputEnabled = false
    }

    private func run(recover: Bool = true, _ body: @escaping @MainActor (Int) async throws -> Void) async -> Bool {
        guard !busy else { return false }
        let epoch = generation
        busy = true; onChange?()
        let task = Task { @MainActor in try await body(epoch) }
        operation = task
        do {
            try await task.value
            guard epoch == generation else { return false }
            operation = nil; busy = false; onChange?()
            return true
        } catch {
            guard epoch == generation else { return false }
            operation = nil; busy = false
            let wasOutput = outputEnabled || session != 0
            if recover, session != 0 {
                // No further PING is sent while attempting the final STOP.
                await stop()
                guard generation == epoch + 1 else { return false }
            } else {
                heartbeat?.cancel(); heartbeat = nil; outputEnabled = false
            }
            connected = false
            message = error.localizedDescription
            onChange?()
            if wasOutput { onOutputLost?(message) }
            return false
        }
    }

    private func apply(_ desired: HapticState, token: UInt32, epoch: Int, starting: Bool) async throws {
        let target = M5LANProtocol.quantized(desired.temperature)
        let pump = M5LANProtocol.appliedPump(desired.stiffness)
        if state?.target != target { try await command(.target, value: target, token: token, epoch: epoch) }
        if state?.pump != pump { try await command(.pump, value: desired.stiffness, token: token, epoch: epoch) }
        // Only an explicit start can enable heating; updates cannot restart it
        // after a local stop, a fault, or the firmware's ten-minute run limit.
        if starting { try await command(.heater, value: 1, token: token, epoch: epoch) }
        try checkOwnership(token)
        guard state?.heater == true, state?.target == target, state?.pump == pump else {
            throw M5LANError.sessionLost
        }
    }

    private func checkOwnership(_ token: UInt32) throws {
        guard let state, state.remote, state.session == token else { throw M5LANError.sessionLost }
        guard state.fault == 0, state.ready else { throw M5LANError.notReady }
    }

    private func startHeartbeat(epoch: Int, token: UInt32) {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                repeat { deadline += .milliseconds(450) } while deadline <= clock.now
                do { try await clock.sleep(until: deadline) } catch { return }
                guard let self, self.generation == epoch, self.session == token else { return }
                // Pending commands also renew the lease. Never overlap HTTP requests.
                if self.busy { continue }
                let success = await self.run { current in
                    guard let last = self.lastFresh, last.duration(to: clock.now) < .milliseconds(1_500) else {
                        throw M5LANError.stale
                    }
                    try await self.command(.ping, token: token, epoch: current)
                    try self.checkOwnership(token)
                    if self.outputEnabled, self.state?.heater != true { throw M5LANError.sessionLost }
                }
                if !success { return }
            }
        }
    }

    private func read(_ epoch: Int) async throws {
        let data = try await request(path: "api/state", body: nil, epoch: epoch)
        try accept(M5LANProtocol.state(data))
    }

    private func command(_ operation: M5LANProtocol.Operation, value: Double = 0, token: UInt32, epoch: Int) async throws {
        guard sequence < UInt32.max else { throw M5LANError.sessionLost }
        sequence += 1
        let number = sequence
        let body = try M5LANProtocol.command(operation, session: token, sequence: number, value: value)
        let data = try await request(path: "api/command", body: body, epoch: epoch)
        let reply = try M5LANProtocol.reply(data, session: token, sequence: number)
        try accept(reply.state)
        if reply.error != 0 { throw M5LANError.rejected(reply.error) }
    }

    private func request(path: String, body: Data?, epoch: Int) async throws -> Data {
        try Task.checkCancellation()
        guard epoch == generation, let address else { throw CancellationError() }
        var request = URLRequest(url: address.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 1)
        request.setValue(pin, forHTTPHeaderField: "X-M5-Key")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard response.statusCode == 200 else { throw M5LANError.http(response.statusCode) }
        return data
    }

    private func accept(_ next: M5LANState) throws {
        if let state, !next.isNewer(than: state) { throw M5LANError.stale }
        state = next; connected = true; lastFresh = clock.now
        onChange?()
    }
}
