import Foundation
import Testing
@testable import MiningCore

private let customMigakuFields = ["Sentence", "Translation", "Target Word", "Definitions", "Screenshot", "Sentence Audio", "Word Audio", "Images", "Example Sentences", "Is Vocabulary Card", "Is Audio Card"]

@Test(arguments: GameLanguage.allCases)
func suggestsExistingMiningDeckAndCustomMigakuType(language: GameLanguage) throws {
    let decks = ["Default", "\(language.name)::Mining"]
    let types = ["Basic", "Migaku \(language.name) Custom"]
    var configuration = AnkiNoteConfiguration.suggested(profile: "Fixture", language: language, decks: decks, noteTypes: types)
    configuration.mapping = AnkiNoteConfiguration.suggestedMapping(fields: customMigakuFields)
    #expect(configuration.deckName == decks[1])
    #expect(configuration.noteTypeName == "Migaku \(language.name) Custom")
    #expect(configuration.mapping[.word] == "Target Word")
    #expect(configuration.mapping[.dictionaryForm] == "Definitions")
    #expect(configuration.mapping[.definition] == "Definitions")
    #expect(configuration.mapping[.wordAudio] == "Word Audio")
    #expect(configuration.mapping[.sentenceAudio] == "Sentence Audio")
    #expect(configuration.mapping[.audioCard] == "Is Audio Card")
    try configuration.validate(fields: customMigakuFields)
}

@Test func storesAnkiTargetsSeparatelyByProfileAndLanguage() throws {
    var preferences = AnkiPreferences()
    let german = AnkiNoteConfiguration(profileName: "Primary", deckName: "German", noteTypeName: "German Custom", mapping: [.wordAudio: "Audio"])
    let spanish = AnkiNoteConfiguration(profileName: "Primary", deckName: "Spanish", noteTypeName: "Spanish Custom", mapping: [.wordAudio: "Sound"])
    let other = AnkiNoteConfiguration(profileName: "Other", deckName: "Default", noteTypeName: "Basic", mapping: [.wordAudio: "Front"])
    preferences.set(german, for: .german)
    preferences.set(spanish, for: .spanish)
    preferences.set(other, for: .german)
    let restored = try JSONDecoder().decode(AnkiPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored.configuration(profile: "Primary", language: .german) == german)
    #expect(restored.configuration(profile: "Primary", language: .spanish) == spanish)
    #expect(restored.configuration(profile: "Other", language: .german) == other)
    #expect(restored.configuration(profile: "Other", language: .spanish) == nil)
}

@Test func rejectsMissingMediaMappingsAndDeletedFields() throws {
    var configuration = AnkiNoteConfiguration(profileName: "Fixture", deckName: "Default", noteTypeName: "Basic", mapping: [:])
    #expect(throws: MiningError.self) { try configuration.validate(fields: ["Front", "Back"]) }
    configuration.mapping = [.wordAudio: "Front"]
    #expect(throws: MiningError.self) { try configuration.validate(fields: ["Front", "Back"]) }
    configuration.mapping = AnkiNoteConfiguration.suggestedMapping(fields: ["Front", "Back"])
    try configuration.validate(fields: ["Front", "Back"])
    #expect(configuration.mapping[.wordAudio] == "Front")
    #expect(configuration.mapping[.sentenceAudio] == "Back")
    configuration.mapping[.definition] = "Deleted field"
    #expect(throws: MiningError.self) { try configuration.validate(fields: ["Front", "Back"]) }
}
