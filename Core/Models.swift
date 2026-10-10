import Foundation

public enum SensorSource: String, Codable, Sendable {
    case watch
    case healthKit
    case simulation
}

public struct SensorReading: Codable, Equatable, Sendable {
    public var id: UUID
    public var measuredAt: Date
    public var heartRate: Double
    public var hrvMilliseconds: Double?
    public var hrvMeasuredAt: Date?
    public var source: SensorSource

    public init(id: UUID = UUID(), measuredAt: Date = Date(), heartRate: Double,
                hrvMilliseconds: Double? = nil, hrvMeasuredAt: Date? = nil,
                source: SensorSource) {
        self.id = id
        self.measuredAt = measuredAt
        self.heartRate = heartRate
        self.hrvMilliseconds = hrvMilliseconds
        self.hrvMeasuredAt = hrvMeasuredAt
        self.source = source
    }
}

public struct HeartRatePoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let measuredAt: Date
    public let heartRate: Double
}

public struct InternalState: Equatable, Sendable {
    public var arousal: Double
    public var smoothedHeartRate: Double
    public var baseline: Double
    public var delta: Double
    public var trendPerMinute: Double
    public var fresh: Bool
    public var hrvMilliseconds: Double?
}

public struct HapticState: Codable, Equatable, Sendable {
    public let temperature: Double
    public let stiffness: Double

    public init(temperature: Double, stiffness: Double) {
        self.temperature = Self.unit(temperature)
        self.stiffness = Self.unit(stiffness)
    }

    public static let neutral = HapticState(temperature: 0.5, stiffness: 0)

    public static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}

public struct DeviceCommand: Codable, Equatable, Sendable {
    public let version: Int
    public let commandID: UUID
    public let sessionID: UUID
    public let sequence: Int
    public let temperature: Double
    public let stiffness: Double
    public let enabled: Bool
    public let ttlMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case version, temperature, stiffness, enabled
        case commandID = "command_id"
        case sessionID = "session_id"
        case sequence
        case ttlMilliseconds = "ttl_ms"
    }

    public init(state: HapticState, enabled: Bool, commandID: UUID = UUID(),
                sessionID: UUID = UUID(), sequence: Int = 1) {
        version = 1
        self.commandID = commandID
        self.sessionID = sessionID
        self.sequence = sequence
        temperature = state.temperature
        stiffness = state.stiffness
        self.enabled = enabled
        ttlMilliseconds = 6_000
    }
}

public struct DeviceStatus: Codable, Sendable {
    public let version: Int
    public let acceptedCommandID: UUID?
    public let state: String
    public let actualTemperature: Double?
    public let actualPressureKPa: Double?
    public let temperatureTarget: Double?
    public let stiffnessTarget: Double?
    public let error: String?
    public let simulated: Bool

    enum CodingKeys: String, CodingKey {
        case version, state, error, simulated
        case acceptedCommandID = "accepted_command_id"
        case actualTemperature = "actual_temperature_c"
        case actualPressureKPa = "actual_pressure_kpa"
        case temperatureTarget = "temperature_target"
        case stiffnessTarget = "stiffness_target"
    }

    public var permitsControl: Bool {
        version == 1 && ["idle", "active", "expired"].contains(state) && error == nil
    }
}

public enum WireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}
