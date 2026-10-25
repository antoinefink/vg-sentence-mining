import Foundation

public enum AnkiFieldRole: String, CaseIterable, Codable, Sendable {
    case word, dictionaryForm, definition, sentence, sentenceTranslation, screenshot, wordAudio, sentenceAudio, vocabularyCard, audioCard

    public var title: String {
        switch self {
        case .word: "Selected word"
        case .dictionaryForm: "Dictionary form"
        case .definition: "English definition"
        case .sentence: "Original sentence"
        case .sentenceTranslation: "English sentence translation"
        case .screenshot: "Screenshot"
        case .wordAudio: "Generated word audio"
        case .sentenceAudio: "Original sentence audio"
        case .vocabularyCard: "Vocabulary card mode (1)"
        case .audioCard: "Audio card mode (1)"
        }
    }

    public var required: Bool { self == .wordAudio || self == .sentenceAudio }
    private var aliases: [String] {
        switch self {
        case .word: ["Target Word", "Word", "Expression"]
        case .dictionaryForm: ["Dictionary form", "Lemma", "Definitions", "Definition", "Meaning"]
        case .definition: ["Definitions", "Definition", "Meaning"]
        case .sentence: ["Sentence", "Original sentence", "Source sentence"]
        case .sentenceTranslation: ["Translation", "Sentence translation", "Sentence EN"]
        case .screenshot: ["Screenshot", "Image", "Picture", "Images"]
        case .wordAudio: ["Word Audio", "Sound word", "Pronunciation"]
        case .sentenceAudio: ["Sentence Audio", "Sound sentence"]
        case .vocabularyCard: ["Is Vocabulary Card"]
        case .audioCard: ["Is Audio Card"]
        }
    }

    fileprivate func suggestedField(in fields: [String]) -> String? {
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        for alias in aliases {
            if let field = fields.first(where: { normalized($0) == normalized(alias) }) { return field }
        }
        guard fields.contains("Front"), fields.contains("Back") else { return nil }
        if self == .wordAudio { return "Front" }
        return self == .vocabularyCard || self == .audioCard ? nil : "Back"
    }
}

public struct AnkiNoteConfiguration: Codable, Equatable, Sendable {
    public var profileName: String
    public var deckName: String
    public var noteTypeName: String
    public var mapping: [AnkiFieldRole: String]

    public init(profileName: String, deckName: String, noteTypeName: String, mapping: [AnkiFieldRole: String]) {
        self.profileName = profileName; self.deckName = deckName; self.noteTypeName = noteTypeName; self.mapping = mapping
    }

    public static func suggested(profile: String, language: GameLanguage, decks: [String], noteTypes: [String]) -> Self {
        let deck = decks.first { $0.localizedCaseInsensitiveContains(language.name) && $0.hasSuffix("::Mining") }
            ?? decks.first { $0.localizedCaseInsensitiveContains(language.name) }
            ?? (decks.contains("Default") ? "Default" : "")
        let noteType = ["Migaku \(language.name) Custom", "Migaku \(language.name)", "Basic"].first { noteTypes.contains($0) } ?? ""
        return Self(profileName: profile, deckName: deck, noteTypeName: noteType, mapping: [:])
    }

    public static func suggestedMapping(fields: [String]) -> [AnkiFieldRole: String] {
        Dictionary(uniqueKeysWithValues: AnkiFieldRole.allCases.compactMap { role in role.suggestedField(in: fields).map { (role, $0) } })
    }

    public func validate(fields: [String]) throws {
        guard !profileName.isEmpty, !deckName.isEmpty, !noteTypeName.isEmpty else { throw MiningError.message("Choose an Anki deck and note type.") }
        for role in AnkiFieldRole.allCases where role.required {
            guard let field = mapping[role], !field.isEmpty else { throw MiningError.message("Choose an Anki field for \(role.title.lowercased()).") }
        }
        for field in mapping.values where !field.isEmpty && !fields.contains(field) {
            throw MiningError.message("The Anki field “\(field)” is missing. Refresh Anki and check the mapping.")
        }
    }
}

public struct AnkiPreferences: Codable, Equatable, Sendable {
    private var profiles: [String: [String: AnkiNoteConfiguration]] = [:]
    public init() {}
    public func configuration(profile: String, language: GameLanguage) -> AnkiNoteConfiguration? { profiles[profile]?[language.rawValue] }
    public mutating func set(_ configuration: AnkiNoteConfiguration, for language: GameLanguage) {
        profiles[configuration.profileName, default: [:]][language.rawValue] = configuration
    }
}

public struct AnkiCatalog: Sendable {
    public let profileName: String
    public let decks: [String]
    public let noteTypes: [String]
}
