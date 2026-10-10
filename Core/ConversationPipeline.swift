import Foundation

public struct ConversationSignal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let measuredAt: Date
    public let text: String
    public let valence: Double
    public let arousal: Double
    public let evidence: [String]
    public let audioEnergy: Double?

    public init(text: String, measuredAt: Date = Date(), audioEnergy: Double? = nil) {
        id = UUID()
        self.measuredAt = measuredAt
        self.text = String(text.prefix(1_000))
        self.audioEnergy = audioEnergy.map(HapticState.unit)
        let result = ConversationAnalyzer.analyze(self.text)
        valence = result.valence
        arousal = result.arousal
        evidence = result.evidence
    }

    public var haptic: HapticState {
        guard !evidence.isEmpty else { return .neutral }
        return HapticState(temperature: 0.25 + valence * 0.5, stiffness: arousal)
    }

    public var impression: String {
        guard !evidence.isEmpty else { return "まだ手がかりがないよ" }
        if arousal > 0.65 { return "張りのある表現" }
        if valence > 0.6 { return "温かく、やわらかな表現" }
        if valence < 0.4 { return "ひんやり、静かな表現" }
        return "ニュートラルな表現"
    }
}

public enum ConversationAnalyzer {
    public struct Result: Equatable, Sendable {
        public let valence: Double
        public let arousal: Double
        public let evidence: [String]
    }

    private struct Entry {
        let word: String
        let valence: Double
        let arousal: Double
    }

    private static let lexicon = [
        Entry(word: "ありがとう", valence: 0.9, arousal: 0.2),
        Entry(word: "うれしい", valence: 0.95, arousal: 0.65),
        Entry(word: "嬉しい", valence: 0.95, arousal: 0.65),
        Entry(word: "楽しい", valence: 0.9, arousal: 0.65),
        Entry(word: "大好き", valence: 0.95, arousal: 0.55),
        Entry(word: "楽しみ", valence: 0.85, arousal: 0.6),
        Entry(word: "わくわく", valence: 0.85, arousal: 0.8),
        Entry(word: "安心", valence: 0.85, arousal: 0.1),
        Entry(word: "落ち着", valence: 0.75, arousal: 0.1),
        Entry(word: "穏やか", valence: 0.8, arousal: 0.1),
        Entry(word: "ほっと", valence: 0.8, arousal: 0.1),
        Entry(word: "リラックス", valence: 0.8, arousal: 0.1),
        Entry(word: "悲しい", valence: 0.1, arousal: 0.25),
        Entry(word: "寂しい", valence: 0.15, arousal: 0.2),
        Entry(word: "疲れ", valence: 0.3, arousal: 0.15),
        Entry(word: "不安", valence: 0.2, arousal: 0.7),
        Entry(word: "心配", valence: 0.25, arousal: 0.65),
        Entry(word: "緊張", valence: 0.3, arousal: 0.8),
        Entry(word: "怖い", valence: 0.1, arousal: 0.85),
        Entry(word: "怒", valence: 0.1, arousal: 0.9),
        Entry(word: "イライラ", valence: 0.1, arousal: 0.9),
        Entry(word: "焦", valence: 0.2, arousal: 0.85),
        Entry(word: "びっくり", valence: 0.5, arousal: 0.85)
    ]

    public static func analyze(_ text: String) -> Result {
        let normalized = String(text.prefix(1_000)).lowercased()
        var evidence: [String] = []
        var valences: [Double] = []
        var arousals: [Double] = []
        for entry in lexicon {
            guard let range = normalized.range(of: entry.word) else { continue }
            let suffix = String(normalized[range.upperBound...].prefix(8))
            let negated = ["じゃない", "ではない", "しない", "してない", "していない", "くない", "ない", "はない",
                           "かない", "けない", "いてない", "いていない", "てない", "ていない", "ってない", "っていない"]
                .contains { suffix.hasPrefix($0) }
            evidence.append(entry.word + (negated ? "（否定）" : ""))
            valences.append(negated ? 1 - entry.valence : entry.valence)
            arousals.append(negated ? 0.3 : entry.arousal)
        }
        guard !valences.isEmpty else { return Result(valence: 0.5, arousal: 0.5, evidence: []) }
        return Result(valence: HapticState.unit(valences.reduce(0, +) / Double(valences.count)),
                      arousal: HapticState.unit(arousals.reduce(0, +) / Double(arousals.count)),
                      evidence: evidence)
    }
}
