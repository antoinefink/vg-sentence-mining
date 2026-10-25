import Foundation

public struct AnkiClient: Sendable {
    private let endpoint = URL(string: "http://127.0.0.1:8765")!
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func decks() async throws -> [String] {
        guard let result = try await call("deckNames") as? [String] else { throw MiningError.message("Anki returned an unexpected deck list.") }
        return result
    }

    public func send(word: String, sentence: String, explanation: WordExplanation, screenshot: Data, sentenceAudio: Data, wordAudio: Data, deck: String) async throws -> Int64 {
        let id = UUID().uuidString.lowercased()
        let back = "<b>\(CardHTML.escape(word))</b><br>\(CardHTML.escape(explanation.dictionaryForm))<br>\(CardHTML.escape(explanation.definition))<br><br>\(CardHTML.escape(sentence))<br>\(CardHTML.escape(explanation.sentenceTranslation))<br>"
        let note: [String: Any] = [
            "deckName": deck, "modelName": "Basic", "fields": ["Front": "", "Back": back],
            "options": ["allowDuplicate": false], "tags": ["vg-sentence-mining"],
            "picture": [["filename": "vg-\(id).jpg", "data": screenshot.base64EncodedString(), "fields": ["Back"]]],
            "audio": [
                ["filename": "vg-word-\(id).mp3", "data": wordAudio.base64EncodedString(), "fields": ["Front"]],
                ["filename": "vg-sentence-\(id).wav", "data": sentenceAudio.base64EncodedString(), "fields": ["Back"]],
            ],
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
