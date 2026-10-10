import Foundation
import HapticCore
import WhisperKit

@main
struct ASRSmoke {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let path = arguments.first, !path.hasPrefix("--") else {
            print("Usage: ASRSmoke audio-file [--download] [--cache cache-directory]")
            return
        }
        let root: URL
        if let index = arguments.firstIndex(of: "--cache"), index + 1 < arguments.count {
            root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build/asr-models", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("model-path.txt")
        let folder: URL
        if arguments.contains("--download") {
            folder = try await WhisperKit.download(variant: "openai_whisper-tiny", downloadBase: root)
            try folder.path.write(to: marker, atomically: true, encoding: .utf8)
        } else {
            folder = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8))
        }
        let whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: root,
            verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        let start = ContinuousClock().now
        let results = try await whisper.transcribe(audioPath: path,
            decodeOptions: DecodingOptions(language: "ja", temperatureFallbackCount: 1, sampleLength: 128,
                skipSpecialTokens: true, withoutTimestamps: true, concurrentWorkerCount: 1))
        let signal = ConversationSignal(text: results.map(\.text).joined())
        print("Transcript: " + signal.text)
        print("Evidence: " + signal.evidence.joined(separator: " / "))
        print("Elapsed: \(start.duration(to: ContinuousClock().now))")
        print(String(decoding: try WireCodec.encode(DeviceCommand(state: signal.haptic, enabled: false)), as: UTF8.self))
    }
}
