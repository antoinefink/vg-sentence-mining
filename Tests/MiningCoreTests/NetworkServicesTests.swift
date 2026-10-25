import Foundation
import Synchronization
import Testing
@testable import MiningCore

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handle = Self.handler.withLock { $0! }
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            let (response, data) = try handle(captured)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct NetworkServicesTests {
    private func session(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        MockProtocol.handler.withLock { $0 = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test(arguments: [GameLanguage.german, .spanish])
    func generatesOnlyTheTargetWordWithTheCorrectLanguage(language: GameLanguage) async throws {
        let requests = Mutex<[URLRequest]>([])
        let audio = Data([73, 68, 51, 1, 2, 3])
        let network = session { request in
            requests.withLock { $0.append(request) }
            let result = request.httpMethod == "POST"
                ? Data(#"{"id":"abc123","status":"succeeded","output":"https://replicate.delivery/test/word.mp3"}"#.utf8) : audio
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, result)
        }
        let word = language == .german ? "Freiheit" : "libertad"
        let result = try await ReplicatePronunciation(session: network).generate(word: word, language: language, token: "test-token")
        #expect(result == audio)
        let sent = requests.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent[0].url?.path == "/v1/models/minimax/speech-2.6-hd/predictions")
        #expect(sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(sent[0].value(forHTTPHeaderField: "Cancel-After") == "60s")
        let body = try JSONSerialization.jsonObject(with: sent[0].httpBody!) as! [String: Any]
        let input = body["input"] as! [String: Any]
        #expect(input["text"] as? String == word)
        #expect(input["language_boost"] as? String == (language == .german ? "German" : "Spanish"))
        #expect(input["voice_id"] as? String == (language == .german ? "German_FriendlyMan" : "Spanish_Narrator"))
    }

    @Test func refusesAudioURLsOutsideReplicateWithoutSendingCredentials() async throws {
        let requests = Mutex<[URLRequest]>([])
        let network = session { request in
            requests.withLock { $0.append(request) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"id":"abc123","status":"succeeded","output":"https://evil.example/word.mp3"}"#.utf8))
        }
        await #expect(throws: MiningError.self) {
            try await ReplicatePronunciation(session: network).generate(word: "Hallo", language: .german, token: "test-token")
        }
        #expect(requests.withLock { $0.allSatisfy { $0.url?.host == "api.replicate.com" } })
    }

    @Test func pollsPendingPredictionsAndDoesNotExposeProviderErrorBodies() async throws {
        let calls = Mutex(0)
        let network = session { request in
            let index = calls.withLock { $0 += 1; return $0 }
            let json = index == 1 ? #"{"id":"abc123","status":"starting"}"# : #"{"id":"abc123","status":"failed","error":"private-provider-detail"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        do {
            _ = try await ReplicatePronunciation(session: network).generate(word: "Hola", language: .spanish, token: "test-token")
            Issue.record("A failed prediction must not return audio")
        } catch {
            #expect(!error.localizedDescription.contains("private-provider-detail"))
        }
        #expect(calls.withLock { $0 } >= 2)
    }

    @Test func exportsWordAudioOnFrontAndSentenceMediaOnBack() async throws {
        let requests = Mutex<[URLRequest]>([])
        let network = session { request in
            requests.withLock { $0.append(request) }
            let action = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["action"] as! String
            let result: Any
            switch action {
            case "getActiveProfile": result = "Fixture"
            case "deckNames": result = ["Default"]
            case "modelFieldNames": result = ["Front", "Back"]
            default: result = 123
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: ["result": result, "error": NSNull()]))
        }
        let wordAudio = Data([1, 2]), sentenceAudio = Data([3, 4]), picture = Data([5, 6])
        let configuration = AnkiNoteConfiguration(profileName: "Fixture", deckName: "Default", noteTypeName: "Basic", mapping: AnkiNoteConfiguration.suggestedMapping(fields: ["Front", "Back"]))
        let id = try await AnkiClient(session: network).send(word: "<Wort>", sentence: "Ein <Satz>.", explanation: .init(dictionaryForm: "Wort", definition: "word", sentenceTranslation: "A sentence."), screenshot: picture, sentenceAudio: sentenceAudio, wordAudio: wordAudio, configuration: configuration)
        #expect(id == 123)
        let request = requests.withLock { $0.last! }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let note = (body["params"] as! [String: Any])["note"] as! [String: Any]
        let fields = note["fields"] as! [String: String]
        #expect(fields["Front"] == "")
        #expect(fields["Back"]!.contains("&lt;Wort&gt;"))
        #expect(fields["Back"]!.contains("Ein &lt;Satz&gt;."))
        let audio = note["audio"] as! [[String: Any]]
        #expect(audio.count == 2)
        #expect(audio[0]["fields"] as? [String] == ["Front"])
        #expect(audio[0]["data"] as? String == wordAudio.base64EncodedString())
        #expect(audio[1]["fields"] as? [String] == ["Back"])
        #expect(audio[1]["data"] as? String == sentenceAudio.base64EncodedString())
        #expect((note["picture"] as! [[String: Any]])[0]["fields"] as? [String] == ["Back"])
    }

    @Test func profileChangesPreventEveryAnkiWrite() async throws {
        let actions = Mutex<[String]>([])
        let network = session { request in
            let action = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["action"] as! String
            actions.withLock { $0.append(action) }
            let result: Any = action == "getActiveProfile" ? "Different profile" : action == "deckNames" ? ["Default"] : ["Front", "Back"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: ["result": result, "error": NSNull()]))
        }
        let configuration = AnkiNoteConfiguration(profileName: "Expected profile", deckName: "Default", noteTypeName: "Basic", mapping: AnkiNoteConfiguration.suggestedMapping(fields: ["Front", "Back"]))
        await #expect(throws: MiningError.self) {
            try await AnkiClient(session: network).send(word: "Wort", sentence: "Ein Satz.", explanation: .init(dictionaryForm: "Wort", definition: "word", sentenceTranslation: "A sentence."), screenshot: Data([1]), sentenceAudio: Data([2]), wordAudio: Data([3]), configuration: configuration)
        }
        #expect(!actions.withLock { $0 }.contains("addNote"))
        #expect(!actions.withLock { $0 }.contains("storeMediaFile"))
    }

    @Test func discoversAnkiProfileDecksAndNoteTypesWithoutAnyWriteActions() async throws {
        let actions = Mutex<[String]>([])
        let network = session { request in
            let action = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["action"] as! String
            actions.withLock { $0.append(action) }
            let result: Any
            switch action {
            case "getActiveProfile": result = "Fixture"
            case "deckNames": result = ["German::Mining", "Spanish::Mining"]
            case "modelNames": result = ["Migaku German Custom", "Migaku Spanish Custom"]
            default: throw MiningError.message("Discovery attempted a non-read action")
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: ["result": result, "error": NSNull()]))
        }
        let catalog = try await AnkiClient(session: network).catalog()
        #expect(catalog.profileName == "Fixture")
        #expect(catalog.decks == ["German::Mining", "Spanish::Mining"])
        #expect(catalog.noteTypes == ["Migaku German Custom", "Migaku Spanish Custom"])
        #expect(actions.withLock { $0 }.allSatisfy { ["getActiveProfile", "deckNames", "modelNames"].contains($0) })
    }

    @Test func rejectsCatalogWhenAnkiSwitchesProfilesDuringDiscovery() async throws {
        let profileReads = Mutex(0)
        let network = session { request in
            let action = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["action"] as! String
            let result: Any
            switch action {
            case "getActiveProfile": result = profileReads.withLock { $0 += 1; return $0 == 1 ? "First profile" : "Second profile" }
            case "deckNames": result = ["Default"]
            case "modelNames": result = ["Basic"]
            default: throw MiningError.message("Discovery attempted a non-read action")
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: ["result": result, "error": NSNull()]))
        }
        await #expect(throws: MiningError.self) { try await AnkiClient(session: network).catalog() }
        #expect(profileReads.withLock { $0 } == 2)
    }

    @Test func mapsMigakuFieldsAndAudioVocabularyModeWithoutChangingTemplates() async throws {
        let captured = Mutex<[URLRequest]>([])
        let names = ["Sentence", "Translation", "Target Word", "Definitions", "Screenshot", "Sentence Audio", "Word Audio", "Is Vocabulary Card", "Is Audio Card"]
        let network = session { request in
            captured.withLock { $0.append(request) }
            let action = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["action"] as! String
            let result: Any
            switch action {
            case "getActiveProfile": result = "Fixture"
            case "deckNames": result = ["German::Mining"]
            case "modelFieldNames": result = names
            default: result = 123
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: ["result": result, "error": NSNull()]))
        }
        let configuration = AnkiNoteConfiguration(profileName: "Fixture", deckName: "German::Mining", noteTypeName: "Migaku German Custom", mapping: AnkiNoteConfiguration.suggestedMapping(fields: names))
        _ = try await AnkiClient(session: network).send(word: "<Wort>", sentence: "Ein <Satz>.", explanation: .init(dictionaryForm: "das Wort", definition: "word & term", sentenceTranslation: "A sentence."), screenshot: Data([1]), sentenceAudio: Data([2]), wordAudio: Data([3]), configuration: configuration)
        let requests = captured.withLock { $0 }
        let body = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        let note = (body["params"] as! [String: Any])["note"] as! [String: Any]
        let fields = note["fields"] as! [String: String]
        #expect(note["modelName"] as? String == "Migaku German Custom")
        #expect(fields["Target Word"] == "&lt;Wort&gt;")
        #expect(fields["Definitions"]!.contains("das Wort"))
        #expect(fields["Definitions"]!.contains("word &amp; term"))
        #expect(fields["Sentence"] == "Ein &lt;Satz&gt;.")
        #expect(fields["Is Audio Card"] == "1")
        #expect(fields["Is Vocabulary Card"] == "1")
        #expect((note["options"] as! [String: Any])["allowDuplicate"] as? Bool == true)
        #expect((note["audio"] as! [[String: Any]])[0]["fields"] as? [String] == ["Word Audio"])
        #expect((note["audio"] as! [[String: Any]])[1]["fields"] as? [String] == ["Sentence Audio"])
        #expect((note["picture"] as! [[String: Any]])[0]["fields"] as? [String] == ["Screenshot"])
        let actions = try requests.map { (try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any])["action"] as! String }
        #expect(actions.allSatisfy { ["getActiveProfile", "deckNames", "modelFieldNames", "addNote"].contains($0) })
    }
}

@Test func keepsReplicateTokensInKeychainAndSupportsReplacementAndRemoval() throws {
    let store = ReplicateTokenStore(service: "io.antoine.vg-sentence-mining.tests.\(UUID().uuidString)")
    defer { try? store.delete() }
    #expect(try store.load() == nil)
    try store.save("fixture-token-one")
    #expect(try store.load() == "fixture-token-one")
    try store.save("fixture-token-two")
    #expect(try store.load() == "fixture-token-two")
    try store.delete()
    #expect(try store.load() == nil)
}
