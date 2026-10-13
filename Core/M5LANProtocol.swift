import Foundation

public enum DeviceConnectionKind: String, CaseIterable, Identifiable, Sendable {
    case gelLink = "gellink"
    case m5Dual = "m5-dual-v3"
    public var id: String { rawValue }
    public var title: String { self == .m5Dual ? "M5ポンプ・ヒーター" : "GelLink API / 模擬サーバー" }
}

public enum M5LANError: LocalizedError {
    case invalidAddress, invalidPIN, invalidResponse, stale, sessionLost, notReady
    case http(Int), rejected(UInt8)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "M5画面のhttp://から始まるLAN URLを指定してください（ポート80）。"
        case .invalidPIN: "M5画面の8桁のLAN PINを入力してください。"
        case .invalidResponse: "M5の応答形式または命令の確認番号が不正です。"
        case .stale: "M5の状態更新が途切れました。再接続してください。"
        case .sessionLost: "M5の操作権が解除されました。出力は手動で再開してください。"
        case .notReady: "M5の温度センサーとPPSの状態を確認してください。"
        case .http(401): "M5画面のLAN PINを確認してください。再起動するとPINが変わります。"
        case .http(429): "LAN PINを確認し、5秒待ってから接続してください。"
        case .http(404): "M5ポンプ・ヒーター用APIがありません。接続方式を確認してください。"
        case .http(let code): "M5との通信に失敗しました（HTTP \(code)）。"
        case .rejected(2): "本体Bで停止しました。Bを離してから出力を再開してください。"
        case .rejected(3): "別の端末が操作中です。その端末で切断するか、M5本体Bで操作を解除してください。"
        case .rejected(5): "M5の操作権が切れました。再接続してください。"
        case .rejected(7): "M5の温度センサーとPPSの状態を確認してください。"
        case .rejected(let code): "M5が指令を拒否しました（コード \(code)）。"
        }
    }
}

public struct M5LANState: Equatable, Sendable {
    public let remote: Bool
    public let heater: Bool
    public let heating: Bool
    public let ready: Bool
    public let session: UInt32
    public let temperature: Double?
    public let target: Double
    public let pump: Double
    public let voltage: Double?
    public let fault: UInt8
    public let notice: UInt8
    public let counter: UInt32

    public var faultMessage: String? {
        switch fault {
        case 0: nil
        case 1: "M5の温度センサー異常"
        case 2: "M5の温度測定が停止"
        case 3: "M5の過熱保護が作動"
        case 4: "M5の10分の試運転時間が終了。確認後にM5を再起動してください。"
        case 5: "PPS通信・出力異常。PPSの入力電源を切ってください。"
        default: "M5の異常"
        }
    }

    public func isNewer(than previous: M5LANState) -> Bool {
        let delta = counter &- previous.counter
        return delta > 0 && delta < 0x8000_0000
    }
}

/// Wire format shared with m5-dual-control/BleWire.h and web/lan-client.js.
public enum M5LANProtocol {
    public enum Operation: UInt8 { case hello = 1, ping, pump, target, heater, stop, release }

    public static func url(_ address: String) -> URL? {
        guard let url = LocalDeviceAddress.url(from: address), url.scheme == "http",
              url.port == nil || url.port == 80 else { return nil }
        return url
    }

    public static func validPIN(_ pin: String) -> Bool {
        pin.utf8.count == 8 && pin.utf8.allSatisfy { (48...57).contains($0) }
    }

    public static func quantized(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
    public static func targetCelsius(_ value: Double) -> Double { 25 + 25 * quantized(value) }
    public static func appliedPump(_ value: Double) -> Double {
        let raw = (value * 10_000).rounded()
        return raw <= 1_900 ? 0 : raw <= 5_450 ? 0.38 : raw <= 8_550 ? 0.71 : 1
    }

    public static func command(_ operation: Operation, session: UInt32, sequence: UInt32,
                               value: Double = 0) throws -> Data {
        guard session != 0, sequence != 0, value.isFinite, (0...1).contains(value),
              operation != .heater || value == 0 || value == 1,
              [.pump, .target, .heater].contains(operation) || value == 0 else {
            throw M5LANError.invalidResponse
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x4d; bytes[1] = 3; bytes[2] = operation.rawValue
        for index in 0..<4 {
            bytes[4 + index] = UInt8(truncatingIfNeeded: session >> (index * 8))
            bytes[8 + index] = UInt8(truncatingIfNeeded: sequence >> (index * 8))
        }
        let scalar = UInt16((value * 10_000).rounded())
        bytes[12] = UInt8(truncatingIfNeeded: scalar)
        bytes[13] = UInt8(truncatingIfNeeded: scalar >> 8)
        return Data(bytes.map { String(format: "%02x", $0) }.joined().utf8)
    }

    public static func state(_ data: Data) throws -> M5LANState {
        let bytes = Array(data)
        guard bytes.count == 20, bytes[0] == 0x4d, bytes[1] == 3, bytes[2] == 0x80,
              bytes[3] <= 15, [0, 38, 71, 100].contains(bytes[14]),
              bytes[15] & 15 <= 5, bytes[15] >> 4 <= 7,
              u16(bytes, 10) <= 10_000 else { throw M5LANError.invalidResponse }
        let temperature = Int16(bitPattern: u16(bytes, 8))
        let voltage = u16(bytes, 12)
        return M5LANState(remote: bytes[3] & 1 != 0, heater: bytes[3] & 2 != 0,
                          heating: bytes[3] & 4 != 0, ready: bytes[3] & 8 != 0,
                          session: u32(bytes, 4), temperature: temperature == .min ? nil : Double(temperature) / 100,
                          target: Double(u16(bytes, 10)) / 10_000, pump: Double(bytes[14]) / 100,
                          voltage: voltage == .max ? nil : Double(voltage) / 1_000,
                          fault: bytes[15] & 15, notice: bytes[15] >> 4, counter: u32(bytes, 16))
    }

    public static func response(_ data: Data, session: UInt32, sequence: UInt32) throws -> M5LANState {
        let reply = try reply(data, session: session, sequence: sequence)
        guard reply.error == 0 else { throw M5LANError.rejected(reply.error) }
        return reply.state
    }

    public static func reply(_ data: Data, session: UInt32, sequence: UInt32) throws -> (state: M5LANState, error: UInt8) {
        let bytes = Array(data)
        guard bytes.count == 32, bytes[0] == 0x4d, bytes[1] == 3, bytes[2] == 0x81,
              u32(bytes, 4) == session, u32(bytes, 8) == sequence else { throw M5LANError.invalidResponse }
        return (try state(Data(bytes[12...])), bytes[3])
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
}
