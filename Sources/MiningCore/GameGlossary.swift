import Foundation

public struct GameGlossary: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var text: String

    public init(id: UUID = UUID(), title: String = "", text: String = "") {
        self.id = id
        self.title = title
        self.text = text
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled glossary" : trimmed
    }

    public var terms: [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: "\r\n,;\t")).compactMap { entry in
            let term = entry
                .replacingOccurrences(of: #"^\s*(?:[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !term.isEmpty, term != "•", term != "-", term != "*",
                  seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }
}

public struct GameGlossaryPreferences: Codable, Equatable, Sendable {
    public var presets: [GameGlossary]
    public var selectedID: UUID?

    public init(presets: [GameGlossary] = [], selectedID: UUID? = nil) {
        self.presets = presets
        self.selectedID = selectedID
    }

    public var selected: GameGlossary? { presets.first { $0.id == selectedID } }

    public mutating func remove(id: UUID) {
        presets.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }
}
