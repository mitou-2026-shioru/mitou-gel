import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    @Published var reachable = false
    @Published var status = "接続準備中"
    @Published var lastDelivery: Date?
    @Published private(set) var companion: CompanionState?
    var onReading: ((SensorReading) -> Void)?
    private var pending: SensorReading?
    private var pendingCompanion: CompanionState?

    override init() {
        super.init()
        guard WCSession.isSupported() else {
            status = "WatchConnectivity非対応"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ reading: SensorReading) {
        pending = reading
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        do {
            let payload: [String: Any] = ["sensor": try WireCodec.encode(reading)]
            try session.updateApplicationContext(payload)
            guard session.isReachable else {
                status = "iPhone待機・最新値を同期予定"
                return
            }
            session.sendMessage(payload, replyHandler: { reply in
                let received = reply["received"] as? Bool == true
                Task { @MainActor in
                    if received {
                        self.lastDelivery = Date()
                        self.status = "iPhoneへ送信済み"
                    }
                }
            }, errorHandler: { error in
                let message = error.localizedDescription
                Task { @MainActor in self.status = message }
            })
        } catch {
            status = error.localizedDescription
        }
    }

    private func refresh() {
        reachable = WCSession.default.isReachable
        status = reachable ? "相手のアプリに接続中" : "相手のアプリの起動待ち"
    }

    func sendCompanion(_ state: CompanionState) {
        pendingCompanion = state
        let session = WCSession.default
        guard session.activationState == .activated,
              let data = try? WireCodec.encode(state) else { return }
        let payload: [String: Any] = ["companion": data]
        do { try session.updateApplicationContext(payload) }
        catch { status = error.localizedDescription }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { _ in }, errorHandler: { _ in })
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let message = error?.localizedDescription
        receive(session.receivedApplicationContext)
        Task { @MainActor in
            self.refresh()
            if let message { self.status = message }
            if let pending = self.pending { self.send(pending) }
            if let pendingCompanion = self.pendingCompanion { self.sendCompanion(pendingCompanion) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let valid = receive(message)
        replyHandler(["received": valid])
    }

    @discardableResult
    nonisolated private func receive(_ payload: [String: Any]) -> Bool {
        if let data = payload["sensor"] as? Data,
           let reading = try? WireCodec.decode(SensorReading.self, from: data) {
            Task { @MainActor in self.onReading?(reading) }
            return true
        }
        if let data = payload["companion"] as? Data,
           let state = try? WireCodec.decode(CompanionState.self, from: data),
           state.haptic.temperature.isFinite, state.haptic.stiffness.isFinite,
           (0...1).contains(state.haptic.temperature), (0...1).contains(state.haptic.stiffness),
           state.input.count <= 32, state.date <= Date() {
            Task { @MainActor in
                if self.companion.map({ state.date > $0.date }) ?? true { self.companion = state }
            }
            return true
        }
        return false
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.status = "Watch切替中" }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
