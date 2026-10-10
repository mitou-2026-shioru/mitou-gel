import Foundation

public struct HapticFrame: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let state: HapticState

    public init(date: Date = Date(), state: HapticState) {
        id = UUID()
        self.date = date
        self.state = state
    }
}

public struct HapticWindow: Sendable {
    public private(set) var frames: [HapticFrame] = []
    public init() {}

    public mutating func append(_ frame: HapticFrame, now: Date = Date()) {
        guard frame.date <= now, now.timeIntervalSince(frame.date) <= 120,
              frames.last.map({ frame.date > $0.date }) ?? true else { return }
        frames.removeAll { now.timeIntervalSince($0.date) > 120 }
        frames.append(frame)
        if frames.count > 300 { frames.removeFirst(frames.count - 300) }
    }

    public func count(seconds: TimeInterval, now: Date = Date()) -> Int {
        recent(seconds: seconds, now: now).count
    }

    public func mean(seconds: TimeInterval, now: Date = Date()) -> HapticState? {
        let selected = recent(seconds: seconds, now: now)
        guard !selected.isEmpty else { return nil }
        return HapticState(temperature: selected.map { $0.state.temperature }.reduce(0, +) / Double(selected.count),
                           stiffness: selected.map { $0.state.stiffness }.reduce(0, +) / Double(selected.count))
    }

    public mutating func reset() { frames.removeAll() }

    private func recent(seconds: TimeInterval, now: Date) -> [HapticFrame] {
        guard seconds.isFinite, seconds > 0 else { return [] }
        return frames.filter { (0...min(seconds, 120)).contains(now.timeIntervalSince($0.date)) }
    }
}

public struct CompanionState: Codable, Sendable {
    public let date: Date
    public let haptic: HapticState
    public let armed: Bool
    public let input: String

    public init(date: Date = Date(), haptic: HapticState, armed: Bool, input: String) {
        self.date = date
        self.haptic = haptic
        self.armed = armed
        self.input = input
    }
}
