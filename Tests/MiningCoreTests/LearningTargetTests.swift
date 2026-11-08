import Testing
@testable import MiningCore

@Test(arguments: [
    ("verwest", "verwesen", "verwesen"),
    ("Häusern", "das Haus", "das Haus"),
    ("grünen", "grün", "grün"),
    ("recuerdo", "recordar", "recordar"),
    ("erinnerte", "sich erinnern", "sich erinnern"),
    ("in der Sonne", "Sonne", "in der Sonne"),
    ("por favor", "favor", "por favor"),
    (" verwest ", " verwesen \n", "verwesen")
])
func learningTargetUsesDictionaryFormsButKeepsSelectedPhrases(selected: String, dictionary: String, expected: String) {
    #expect(LearningTarget.resolve(selectedText: selected, dictionaryForm: dictionary) == expected)
}

@Test func singleWordsWaitForTheirDictionaryFormBeforePronunciationOrExport() {
    #expect(LearningTarget.resolve(selectedText: "verwest", dictionaryForm: " \n") == nil)
    #expect(LearningTarget.resolve(selectedText: "", dictionaryForm: "verwesen") == nil)
    #expect(LearningTarget.resolve(selectedText: "in der Sonne", dictionaryForm: "") == "in der Sonne")
}
