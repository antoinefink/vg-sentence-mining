import Foundation
import Testing
@testable import MiningCore

@Test func parsesPastedGlossaryListsWithoutSplittingPhrases() {
    let glossary = GameGlossary(title: "Game", text: """
        • Über-Erde
        - Geralt von Riva
        1. Kaer Morhen
        2) Vesemir; Ciri, Yennefer\tGeralt von Riva
        ÜBER-ERDE
        """)
    #expect(glossary.terms == ["Über-Erde", "Geralt von Riva", "Kaer Morhen", "Vesemir", "Ciri", "Yennefer"])
}

@Test func glossaryPreservesAccentsAndHandlesCopiedWindowsLines() {
    let glossary = GameGlossary(title: "España", text: "  Peña\r\nPe\u{006E}\u{0303}a\r\n\r\nEl Árbol\n-Mehr\n* ")
    #expect(glossary.terms == ["Peña", "El Árbol", "-Mehr"])
    #expect(GameGlossary(title: " ", text: " \n\t").terms.isEmpty)
}

@Test func savesRawGlossariesAndSelectionAcrossReloads() throws {
    let first = GameGlossary(title: "The Witcher", text: "Geralt\nCiri")
    let second = GameGlossary(title: "Otro juego", text: "Peña, El Árbol")
    let original = GameGlossaryPreferences(presets: [first, second], selectedID: second.id)
    let restored = try JSONDecoder().decode(GameGlossaryPreferences.self, from: JSONEncoder().encode(original))
    #expect(restored == original)
    #expect(restored.selected?.title == "Otro juego")
    #expect(restored.selected?.text == second.text)
}

@Test func deletingTheSelectedGlossaryDisablesItWithoutDeletingOtherPresets() {
    let first = GameGlossary(title: "First", text: "Term")
    let second = GameGlossary(title: "Second", text: "Another")
    var preferences = GameGlossaryPreferences(presets: [first, second], selectedID: first.id)
    preferences.remove(id: second.id)
    #expect(preferences.selected == first)
    preferences.remove(id: first.id)
    #expect(preferences.selectedID == nil)
    #expect(preferences.selected == nil)
    #expect(preferences.presets.isEmpty)
}
