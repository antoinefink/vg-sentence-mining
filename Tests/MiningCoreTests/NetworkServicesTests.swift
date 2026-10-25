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
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"result":123,"error":null}"#.utf8))
        }
        let wordAudio = Data([1, 2]), sentenceAudio = Data([3, 4]), picture = Data([5, 6])
        let id = try await AnkiClient(session: network).send(word: "<Wort>", sentence: "Ein <Satz>.", explanation: .init(dictionaryForm: "Wort", definition: "word", sentenceTranslation: "A sentence."), screenshot: picture, sentenceAudio: sentenceAudio, wordAudio: wordAudio, deck: "Default")
        #expect(id == 123)
        let request = requests.withLock { $0[0] }
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
