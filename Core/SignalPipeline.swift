import Foundation

public struct SignalPipeline: Sendable {
    public private(set) var points: [HeartRatePoint] = []
    public private(set) var latest: SensorReading?
    public var baseline: Double = 70
    public let staleAfter: TimeInterval = 30

    public init() {}

    @discardableResult
    public mutating func ingest(_ reading: SensorReading, now: Date = Date()) -> Bool {
        guard reading.heartRate.isFinite, (25...240).contains(reading.heartRate),
              reading.measuredAt.timeIntervalSince(now) <= 5,
              now.timeIntervalSince(reading.measuredAt) <= 120 else { return false }
        if let latest, reading.measuredAt < latest.measuredAt { return false }
        if let latest, latest.source != reading.source {
            points.removeAll()
        }
        latest = reading
        points.removeAll { now.timeIntervalSince($0.measuredAt) > 120 }
        if !points.contains(where: { $0.id == reading.id || $0.measuredAt == reading.measuredAt }) {
            points.append(HeartRatePoint(id: reading.id, measuredAt: reading.measuredAt,
                                         heartRate: reading.heartRate))
        }
        return true
    }

    public mutating func reset() {
        points.removeAll()
        latest = nil
    }

    public mutating func calibrate(now: Date = Date()) -> Bool {
        let recent = points.filter { now.timeIntervalSince($0.measuredAt) <= 30 }
        guard recent.count >= 3, state(now: now).fresh else { return false }
        baseline = recent.map(\.heartRate).reduce(0, +) / Double(recent.count)
        return true
    }

    public func state(now: Date = Date()) -> InternalState {
        let recent = points.filter { now.timeIntervalSince($0.measuredAt) <= 30 }
        let average = recent.isEmpty ? (latest?.heartRate ?? baseline)
            : recent.map(\.heartRate).reduce(0, +) / Double(recent.count)
        let fresh = latest.map { now.timeIntervalSince($0.measuredAt) <= staleAfter } ?? false
        let hrv: Double? = latest.flatMap { reading in
            guard let value = reading.hrvMilliseconds, value.isFinite, value > 0,
                  let date = reading.hrvMeasuredAt,
                  (0...300).contains(now.timeIntervalSince(date)) else { return nil }
            return value
        }
        return InternalState(arousal: HapticState.unit(0.5 + (average - baseline) / 60),
                             smoothedHeartRate: average, baseline: baseline,
                             delta: average - baseline, trendPerMinute: trend(now: now),
                             fresh: fresh, hrvMilliseconds: hrv)
    }

    private func trend(now: Date) -> Double {
        let recent = points.filter { now.timeIntervalSince($0.measuredAt) <= 60 }
        guard recent.count >= 3, let first = recent.first,
              let last = recent.last, last.measuredAt.timeIntervalSince(first.measuredAt) >= 10
        else { return 0 }
        let times = recent.map { $0.measuredAt.timeIntervalSince(first.measuredAt) }
        let meanTime = times.reduce(0, +) / Double(times.count)
        let meanHR = recent.map(\.heartRate).reduce(0, +) / Double(recent.count)
        let numerator = zip(times, recent).reduce(0.0) {
            $0 + ($1.0 - meanTime) * ($1.1.heartRate - meanHR)
        }
        let denominator = times.reduce(0.0) { $0 + pow($1 - meanTime, 2) }
        return denominator > 0 ? numerator / denominator * 60 : 0
    }
}

public struct HapticMapping: Sendable {
    public init() {}

    public func map(_ state: InternalState) -> HapticState {
        guard state.fresh else { return .neutral }
        return HapticState(temperature: 0.25 + state.arousal * 0.5,
                           stiffness: state.arousal)
    }
}

public enum LocalDeviceAddress {
    public static func url(from text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased() else { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let segments = parts.compactMap { Int($0) }
        let privateIPv4 = parts.count == 4 && segments.count == 4 && segments.allSatisfy { (0...255).contains($0) }
            && (segments[0] == 10 || segments[0] == 127
                || (segments[0] == 192 && segments[1] == 168)
                || (segments[0] == 172 && (16...31).contains(segments[1])))
        guard host == "localhost" || host.hasSuffix(".local") || privateIPv4 else { return nil }
        return components.url
    }
}

public enum CSV {
    public static func row(_ values: [String]) -> String {
        values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: ",") + "\n"
    }
}
