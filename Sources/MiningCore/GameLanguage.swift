import Foundation

public enum GameLanguage: String, CaseIterable, Codable, Sendable {
    case czech = "cs", danish = "da", dutch = "nl", english = "en", finnish = "fi"
    case french = "fr", german = "de", greek = "el", hungarian = "hu", indonesian = "id"
    case italian = "it", polish = "pl", portuguese = "pt", romanian = "ro", russian = "ru"
    case spanish = "es", swedish = "sv", turkish = "tr", ukrainian = "uk", vietnamese = "vi"

    public var name: String {
        switch self {
        case .czech: "Czech"
        case .danish: "Danish"
        case .dutch: "Dutch"
        case .english: "English"
        case .finnish: "Finnish"
        case .french: "French"
        case .german: "German"
        case .greek: "Greek"
        case .hungarian: "Hungarian"
        case .indonesian: "Indonesian"
        case .italian: "Italian"
        case .polish: "Polish"
        case .portuguese: "Portuguese"
        case .romanian: "Romanian"
        case .russian: "Russian"
        case .spanish: "Spanish"
        case .swedish: "Swedish"
        case .turkish: "Turkish"
        case .ukrainian: "Ukrainian"
        case .vietnamese: "Vietnamese"
        }
    }

    public var speechLocale: String {
        switch self {
        case .czech: "cs-CZ"
        case .danish: "da-DK"
        case .dutch: "nl-NL"
        case .english: "en-US"
        case .finnish: "fi-FI"
        case .french: "fr-FR"
        case .german: "de-DE"
        case .greek: "el-GR"
        case .hungarian: "hu-HU"
        case .indonesian: "id-ID"
        case .italian: "it-IT"
        case .polish: "pl-PL"
        case .portuguese: "pt-PT"
        case .romanian: "ro-RO"
        case .russian: "ru-RU"
        case .spanish: "es-ES"
        case .swedish: "sv-SE"
        case .turkish: "tr-TR"
        case .ukrainian: "uk-UA"
        case .vietnamese: "vi-VN"
        }
    }

    public var sampleWord: String {
        switch self {
        case .czech: "svoboda"
        case .danish: "frihed"
        case .dutch: "vrijheid"
        case .english: "freedom"
        case .finnish: "vapaus"
        case .french: "liberté"
        case .german: "Freiheit"
        case .greek: "ελευθερία"
        case .hungarian: "szabadság"
        case .indonesian: "kebebasan"
        case .italian: "libertà"
        case .polish: "wolność"
        case .portuguese: "liberdade"
        case .romanian: "libertate"
        case .russian: "свобода"
        case .spanish: "libertad"
        case .swedish: "frihet"
        case .turkish: "özgürlük"
        case .ukrainian: "свобода"
        case .vietnamese: "tự do"
        }
    }
}

public struct LanguagePreferences: Sendable {
    private var enabled: Set<GameLanguage>
    public private(set) var selected: GameLanguage
    public var languages: [GameLanguage] { GameLanguage.allCases.filter { enabled.contains($0) } }

    public init(languages: [GameLanguage] = [.german, .spanish], selected: GameLanguage = .german) {
        let choices = Set(languages.isEmpty ? [.german, .spanish] : languages)
        enabled = choices
        self.selected = choices.contains(selected) ? selected : GameLanguage.allCases.first { choices.contains($0) }!
    }

    public mutating func select(_ language: GameLanguage) {
        if enabled.contains(language) { selected = language }
    }

    public mutating func setEnabled(_ language: GameLanguage, enabled value: Bool) {
        if value { enabled.insert(language) }
        else if enabled.count > 1 { enabled.remove(language) }
        if !enabled.contains(selected) { selected = languages[0] }
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let saved = defaults.dictionary(forKey: "languagePreferences"), let codes = saved["enabled"] as? [String] else { return .init() }
        return Self(languages: codes.compactMap(GameLanguage.init(rawValue:)),
                    selected: (saved["selected"] as? String).flatMap(GameLanguage.init(rawValue:)) ?? .german)
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(["enabled": languages.map(\.rawValue), "selected": selected.rawValue], forKey: "languagePreferences")
    }
}
