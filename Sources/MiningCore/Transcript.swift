import Foundation

public enum GameLanguage: String, CaseIterable, Codable, Sendable {
    case german = "de", spanish = "es"
    public var name: String { self == .german ? "German" : "Spanish" }
}

public struct SpokenWord: Identifiable, Equatable, Sendable {
    public var id: String { "\(start)-\(text)" }
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: Int?
    public init(text: String, start: TimeInterval, end: TimeInterval, speaker: Int? = nil) {
        self.text = text; self.start = start; self.end = end; self.speaker = speaker
    }
}

public struct Dialogue: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var words: [SpokenWord]
    public var capturedAt: Date
    public var language: GameLanguage
    public var text: String { words.map(\.text).joined(separator: " ") }
    public var start: TimeInterval { words.first?.start ?? 0 }
    public var end: TimeInterval { words.map(\.end).max() ?? start }
    public var speaker: Int? { words.first?.speaker }
    public var expiresAt: Date { capturedAt.addingTimeInterval(1800) }
    public init(id: UUID = UUID(), words: [SpokenWord], capturedAt: Date, language: GameLanguage) {
        self.id = id; self.words = words; self.capturedAt = capturedAt; self.language = language
    }
}

/// Joins timestamped words across recognition windows without joining separate speakers.
public struct TranscriptAssembler: Sendable {
    public private(set) var rows: [Dialogue] = []
    public init() {}

    public mutating func append(_ words: [SpokenWord], sessionStart: Date, language: GameLanguage) {
        for word in words.sorted(by: { $0.start < $1.start }) {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let normalized = word.text.trimmingCharacters(in: .punctuationCharacters).lowercased()
            let repeatedWindowWord = rows.suffix(2).flatMap(\.words).suffix(8).contains { previous in
                let overlap = min(previous.end, word.end) - max(previous.start, word.start)
                let shorter = min(previous.end - previous.start, word.end - word.start)
                let sameInterval = abs(previous.start - word.start) < 0.001 && abs(previous.end - word.end) < 0.001
                return previous.text.trimmingCharacters(in: .punctuationCharacters).lowercased() == normalized
                    && (sameInterval || (overlap >= 0.08 && overlap >= shorter * 0.25))
                    && (previous.speaker == nil || word.speaker == nil || previous.speaker == word.speaker)
            }
            if repeatedWindowWord { continue }
            if let last = rows.last,
               last.speaker == word.speaker,
               word.start - last.end < 1.0,
               last.end - last.start < 16,
               ![".", "?", "!", "…"].contains(where: last.text.hasSuffix) {
                rows[rows.count - 1].words.append(word)
            } else {
                rows.append(Dialogue(words: [word], capturedAt: sessionStart.addingTimeInterval(word.start), language: language))
            }
        }
    }

    public mutating func expire(now: Date) {
        rows.removeAll { $0.expiresAt <= now }
    }
}

public struct WordExplanation: Codable, Equatable, Sendable {
    public var dictionaryForm: String
    public var definition: String
    public var sentenceTranslation: String
    public init(dictionaryForm: String, definition: String, sentenceTranslation: String) {
        self.dictionaryForm = dictionaryForm; self.definition = definition; self.sentenceTranslation = sentenceTranslation
    }
}

public enum MiningError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

public enum CardHTML {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
