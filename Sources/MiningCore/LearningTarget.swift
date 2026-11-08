import Foundation

public enum LearningTarget {
    public static func resolve(selectedText: String, dictionaryForm: String) -> String? {
        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return nil }
        if selected.split(whereSeparator: \.isWhitespace).count > 1 { return selected }
        let dictionary = dictionaryForm.trimmingCharacters(in: .whitespacesAndNewlines)
        return dictionary.isEmpty ? nil : dictionary
    }
}
