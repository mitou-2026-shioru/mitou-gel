import Combine
import Foundation

@MainActor
final class DeviceClient: ObservableObject {
    @Published private(set) var status: DeviceStatus?
    @Published private(set) var connected = false
    @Published private(set) var message = "未接続"
    @Published private(set) var lastResponse: Date?
    @Published private(set) var lastCommand: DeviceCommand?
    @Published private(set) var kind: DeviceConnectionKind = .gelLink
    @Published private(set) var m5State: M5LANState?
    @Published private(set) var busy = false
    var onOutputLost: ((String) -> Void)?
    private var baseURL: URL?
    private var configuredAddress = ""
    private var configuredPIN = ""
    private var inFlight: Task<DeviceStatus, Error>?
    private var generation = 0
    private var sessionID = UUID()
    private var sequence = 0
    private let session: URLSession
    private let m5: M5LANClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        self.session = session
        m5 = M5LANClient { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw M5LANError.invalidResponse }
            return (data, response)
        }
        m5.onChange = { [weak self] in self?.syncM5() }
        m5.onOutputLost = { [weak self] reason in self?.onOutputLost?(reason) }
    }

    func configure(address: String, kind: DeviceConnectionKind = .gelLink, pin: String = "") -> Bool {
        generation += 1
        inFlight?.cancel()
        connected = false
        status = nil
        lastCommand = nil
        lastResponse = nil
        m5State = nil
        busy = false
        sessionID = UUID()
        sequence = 0
        self.kind = kind
        configuredAddress = address
        configuredPIN = pin
        baseURL = LocalDeviceAddress.url(from: address)
        if kind == .m5Dual { return m5.configure(address: address, pin: pin) }
        message = baseURL == nil ? "LAN内のURLを指定してください" : "接続確認待ち"
        return baseURL != nil
    }

    func matches(address: String, kind: DeviceConnectionKind, pin: String) -> Bool {
        configuredAddress == address && self.kind == kind && (kind != .m5Dual || configuredPIN == pin)
    }

    func connect() async {
        if kind == .m5Dual { _ = await m5.connect() }
        else { await send(state: .neutral, enabled: false) }
    }

    func start(state: HapticState) async -> Bool {
        if kind == .gelLink {
            await send(state: state, enabled: true)
            return connected && status?.permitsControl == true
        }
        let success = await m5.startOutput(state)
        if success { acknowledgeM5(state: state) }
        return success
    }

    func poll() async {
        if kind == .m5Dual { await m5.refresh(); return }
        guard inFlight == nil else { return }
        await perform(path: "v1/status", command: nil)
    }

    func send(state: HapticState, enabled: Bool) async {
        if kind == .m5Dual {
            if enabled {
                if await m5.updateOutput(state) { acknowledgeM5(state: state) }
            } else {
                lastCommand = nil
                await m5.stop()
            }
            return
        }
        sequence += 1
        await perform(path: "v1/state", command: DeviceCommand(state: state, enabled: enabled,
                                                               sessionID: sessionID, sequence: sequence))
    }

    private func perform(path: String, command: DeviceCommand?) async {
        guard let baseURL else { return }
        generation += 1
        let requestGeneration = generation
        inFlight?.cancel()
        busy = true
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let command {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? WireCodec.encode(command)
            lastCommand = command
        }
        let task = Task<DeviceStatus, Error> {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw DeviceError.invalidResponse
            }
            guard data.count <= 65_536 else { throw DeviceError.invalidResponse }
            let received = try WireCodec.decode(DeviceStatus.self, from: data)
            guard received.version == 1 else { throw DeviceError.invalidResponse }
            if let command, received.acceptedCommandID != command.commandID {
                throw DeviceError.unacknowledged
            }
            return received
        }
        inFlight = task
        do {
            let received = try await task.value
            guard requestGeneration == generation else { return }
            status = received
            connected = true
            lastResponse = Date()
            message = received.error ?? (received.simulated ? "模擬デバイスに接続" : "デバイスに接続")
        } catch {
            guard requestGeneration == generation else { return }
            connected = false
            message = "通信断: \(error.localizedDescription)"
        }
        if requestGeneration == generation { inFlight = nil; busy = false }
    }

    private func acknowledgeM5(state: HapticState) {
        sequence += 1
        // App-level transaction ID, assigned only after all M5 ACKs and the
        // applied target/pump/heater state have been checked.
        lastCommand = DeviceCommand(state: state, enabled: true, sessionID: sessionID, sequence: sequence)
        syncM5()
    }

    private func syncM5() {
        guard kind == .m5Dual else { return }
        connected = m5.connected; busy = m5.busy; message = m5.message
        let previousCounter = m5State?.counter
        m5State = m5.state
        guard let raw = m5.state else { status = nil; return }
        if connected, previousCounter != raw.counter { lastResponse = Date() }
        let foreignOwner = raw.remote && !m5.ownsSession
        let error = raw.faultMessage ?? (foreignOwner ? M5LANError.rejected(3).localizedDescription : nil)
        let state = error != nil ? "fault" : m5.outputEnabled ? "active" : raw.ready ? "idle" : "starting"
        let accepted = lastCommand.flatMap { command -> UUID? in
            guard connected, m5.outputEnabled, raw.heater,
                  raw.target == M5LANProtocol.quantized(command.temperature),
                  raw.pump == M5LANProtocol.appliedPump(command.stiffness) else { return nil }
            return command.commandID
        }
        status = DeviceStatus(version: 1, acceptedCommandID: accepted, state: state,
                              actualTemperature: raw.temperature, actualPressureKPa: nil,
                              temperatureTarget: raw.target, stiffnessTarget: raw.pump,
                              error: error, simulated: false)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum DeviceError: LocalizedError {
    case invalidResponse
    case unacknowledged

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "APIの応答が不正です"
        case .unacknowledged: return "制御命令が確認されませんでした"
        }
    }
}
