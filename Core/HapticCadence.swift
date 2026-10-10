import Foundation

public struct HapticCadence: Sendable {
    public private(set) var deadline: ContinuousClock.Instant

    public init(start: ContinuousClock.Instant = ContinuousClock().now) {
        deadline = start
    }

    public mutating func advance(past now: ContinuousClock.Instant) {
        repeat { deadline += .seconds(2) } while deadline <= now
    }
}
