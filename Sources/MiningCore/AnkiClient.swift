import Foundation

public struct AnkiClient: Sendable {
    private let endpoint = URL(string: "http://127.0.0.1:8765")!
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func decks() async throws -> [String] {
        guard let result = try await call("deckNames") as? [String] else { throw MiningError.message("Anki returned an unexpected deck list.") }
        return result
    }

    public func activeProfile() async throws -> String {
        guard let profile = try await call("getActiveProfile") as? String, !profile.isEmpty else { throw MiningError.message("Open an Anki profile, then refresh.") }
        return profile
    }

    public func fields(noteType: String) async throws -> [String] {
        guard let fields = try await call("modelFieldNames", parameters: ["modelName": noteType]) as? [String], !fields.isEmpty else { throw MiningError.message("Anki returned an unexpected field list.") }
        return fields
    }

    public func catalog() async throws -> AnkiCatalog {
        let profile = try await activeProfile()
        async let deckNames = decks()
        let types = try await call("modelNames") as? [String]
        let allDecks = try await deckNames
        guard let types, try await activeProfile() == profile else { throw MiningError.message("Anki changed profiles. Refresh to reconnect.") }
        return AnkiCatalog(profileName: profile, decks: allDecks, noteTypes: types)
    }

    public func send(word: String, sentence: String, explanation: WordExplanation, screenshot: Data, sentenceAudio: Data, wordAudio: Data, configuration: AnkiNoteConfiguration) async throws -> Int64 {
        let fieldNames = try await fields(noteType: configuration.noteTypeName)
        try configuration.validate(fields: fieldNames)
        guard try await decks().contains(configuration.deckName) else { throw MiningError.message("The selected Anki deck is missing. Refresh Anki in Settings.") }
        guard try await activeProfile() == configuration.profileName else { throw MiningError.message("Anki changed profiles. Refresh and select an export destination in Settings.") }
        let id = UUID().uuidString.lowercased()
        var values = Dictionary(uniqueKeysWithValues: fieldNames.map { ($0, "") })
        for role in AnkiFieldRole.allCases {
            guard let field = role.isAutomatic ? role.suggestedField(in: fieldNames) : configuration.mapping[role], !field.isEmpty else { continue }
            let content: String
            switch role {
            case .word: content = CardHTML.escape(word)
            case .dictionaryForm: content = "<b>\(CardHTML.escape(explanation.dictionaryForm))</b>"
            case .definition: content = CardHTML.escape(explanation.definition)
            case .sentence: content = CardHTML.escape(sentence)
            case .sentenceTranslation: content = CardHTML.escape(explanation.sentenceTranslation)
            case .vocabularyCard, .audioCard: content = "1"
            case .screenshot, .wordAudio, .sentenceAudio: continue
            }
            let separator = values[field]?.isEmpty == false ? "<br>" : ""
            values[field, default: ""] += separator + content
        }
        let pictures: [[String: Any]] = configuration.mapping[.screenshot].flatMap { field in
            field.isEmpty ? nil : [["filename": "vg-\(id).jpg", "data": screenshot.base64EncodedString(), "fields": [field]]]
        } ?? []
        let audio: [[String: Any]] = [
            ["filename": "vg-word-\(id).mp3", "data": wordAudio.base64EncodedString(), "fields": [configuration.mapping[.wordAudio]!]],
            ["filename": "vg-sentence-\(id).wav", "data": sentenceAudio.base64EncodedString(), "fields": [configuration.mapping[.sentenceAudio]!]],
        ]
        let note: [String: Any] = [
            "deckName": configuration.deckName, "modelName": configuration.noteTypeName, "fields": values,
            "options": ["allowDuplicate": configuration.mapping[.sentence] == fieldNames.first], "tags": ["vg-sentence-mining"],
            "picture": pictures, "audio": audio,
        ]
        guard let result = try await call("addNote", parameters: ["note": note]) as? NSNumber else {
            throw MiningError.message("Anki did not confirm that the note was added.")
        }
        return result.int64Value
    }

    private func call(_ action: String, parameters: [String: Any] = [:]) async throws -> Any {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": parameters])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiningError.message("Cannot reach AnkiConnect. Open Anki and enable its AnkiConnect add-on.")
        }
        if let error = body["error"] as? String { throw MiningError.message(error) }
        return body["result"] ?? NSNull()
    }
}
