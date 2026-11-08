import Foundation
import Testing
@testable import MiningCore

@Test func enabledLanguagesPersistAndCannotBecomeEmpty() throws {
    let suite = "LanguagePreferencesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = LanguagePreferences.load(defaults: defaults)
    #expect(Set(preferences.languages) == [.german, .spanish])
    preferences.setEnabled(.french, enabled: true)
    preferences.select(.french)
    preferences.setEnabled(.german, enabled: false)
    preferences.setEnabled(.spanish, enabled: false)
    preferences.setEnabled(.french, enabled: false)
    preferences.select(.italian)
    preferences.save(defaults: defaults)
    let restored = LanguagePreferences.load(defaults: defaults)
    #expect(restored.languages == [.french])
    #expect(restored.selected == .french)
}

@Test func disablingCurrentLanguageSelectsAnEnabledLanguage() {
    var preferences = LanguagePreferences()
    preferences.setEnabled(.german, enabled: false)
    #expect(preferences.selected == .spanish)
}

@Test func unknownSavedLanguagesDoNotDiscardKnownChoices() throws {
    let suite = "LanguagePreferencesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["enabled": ["fr", "xx"], "selected": "xx"], forKey: "languagePreferences")
    let preferences = LanguagePreferences.load(defaults: defaults)
    #expect(preferences.languages == [.french])
    #expect(preferences.selected == .french)
    defaults.set(["enabled": [], "selected": "xx"], forKey: "languagePreferences")
    #expect(Set(LanguagePreferences.load(defaults: defaults).languages) == [.german, .spanish])
}

@Test func transcriptionCompatibilityIncludesTheWordAligner() {
    #expect(TranscriptionModel.parakeetUltra.supports(.french))
    #expect(!TranscriptionModel.parakeetUltra.supports(.turkish))
    #expect(TranscriptionModel.whisperLargeV3.supports(.turkish))
    #expect(TranscriptionModel.qwen3ASR.supports(.russian))
    #expect(!TranscriptionModel.qwen3ASR.supports(.dutch))
    #expect(PronunciationModel.inworldTTS2.supports(.dutch))
    #expect(!PronunciationModel.inworldTTS2.supports(.ukrainian))
    #expect(PronunciationModel.gemini31Flash.supports(.ukrainian))
}
