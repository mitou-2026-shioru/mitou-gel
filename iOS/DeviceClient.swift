import Combine
import Foundation

@MainActor
final class DeviceClient: ObservableObject {
    @Published private(set) var status: DeviceStatus?
    @Published private(set) var connected = false
    @Published private(set) var message = "未接続"
    @Published private(set) var lastResponse: Date?
    @Published private(set) var lastCommand: DeviceCommand?
    private var baseURL: URL?
    private var inFlight: Task<DeviceStatus, Error>?
    private var generation = 0
    private var sessionID = UUID()
    private var sequence = 0
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    func configure(address: String) -> Bool {
        generation += 1
        inFlight?.cancel()
        connected = false
        status = nil
        lastCommand = nil
        lastResponse = nil
        sessionID = UUID()
        sequence = 0
        baseURL = LocalDeviceAddress.url(from: address)
        message = baseURL == nil ? "LAN内のURLを指定してください" : "接続確認待ち"
        return baseURL != nil
    }

    func poll() async {
        guard inFlight == nil else { return }
        await perform(path: "v1/status", command: nil)
    }

    func send(state: HapticState, enabled: Bool) async {
        sequence += 1
        await perform(path: "v1/state", command: DeviceCommand(state: state, enabled: enabled,
                                                               sessionID: sessionID, sequence: sequence))
    }

    private func perform(path: String, command: DeviceCommand?) async {
        guard let baseURL else { return }
        generation += 1
        let requestGeneration = generation
        inFlight?.cancel()
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
        if requestGeneration == generation { inFlight = nil }
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
