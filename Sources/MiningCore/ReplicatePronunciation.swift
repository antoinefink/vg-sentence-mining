import Foundation

public enum PronunciationModel: String, CaseIterable, Sendable {
    case speech26HD = "minimax/speech-2.6-hd"
    case speech28HD = "minimax/speech-2.8-hd"
    case speech28Turbo = "minimax/speech-2.8-turbo"

    public var name: String {
        switch self {
        case .speech26HD: "MiniMax Speech 2.6 HD"
        case .speech28HD: "MiniMax Speech 2.8 HD"
        case .speech28Turbo: "MiniMax Speech 2.8 Turbo"
        }
    }

    public var detail: String {
        switch self {
        case .speech26HD: "Original high-quality model."
        case .speech28HD: "Newer model tuned for audio quality."
        case .speech28Turbo: "Newer model tuned for speed."
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ReplicatePronunciation: Sendable {
    private struct Prediction: Decodable {
        let id: String
        let status: String
        let output: String?
    }
    private let session: URLSession
    private let api = URL(string: "https://api.replicate.com/v1/")!

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func generate(word: String, language: GameLanguage, model: PronunciationModel = .speech26HD, token: String) async throws -> Data {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MiningError.message("Select a word to pronounce.") }
        var predictionID: String?
        var predictionPending = false
        do {
            let input: [String: Any] = ["text": text, "voice_id": language == .german ? "German_FriendlyMan" : "Spanish_Narrator", "language_boost": language.name, "audio_format": "mp3", "sample_rate": 32000, "speed": 1, "emotion": "neutral"]
            var request = authorized(api.appendingPathComponent("models/\(model.rawValue)/predictions"), token: token)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("wait=10", forHTTPHeaderField: "Prefer")
            request.setValue("60s", forHTTPHeaderField: "Cancel-After")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["input": input])
            var prediction = try await fetchPrediction(request)
            guard !prediction.id.isEmpty, prediction.id.count <= 128, prediction.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw MiningError.message("Replicate returned an invalid prediction.")
            }
            predictionID = prediction.id
            predictionPending = prediction.status == "starting" || prediction.status == "processing"
            let deadline = ContinuousClock.now.advanced(by: .seconds(75))
            while prediction.status == "starting" || prediction.status == "processing" {
                guard ContinuousClock.now < deadline else { throw MiningError.message("Word audio took too long. Please retry.") }
                try await Task.sleep(for: .seconds(1))
                prediction = try await fetchPrediction(authorized(api.appendingPathComponent("predictions/\(predictionID!)"), token: token))
                predictionPending = prediction.status == "starting" || prediction.status == "processing"
            }
            guard prediction.status == "succeeded", let output = prediction.output, let url = URL(string: output),
                  url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  let host = url.host?.lowercased(), host == "replicate.delivery" || host.hasSuffix(".replicate.delivery") else {
                throw MiningError.message("Replicate could not generate word audio. Please retry.")
            }
            let (bytes, response) = try await session.bytes(for: authorized(url, token: token))
            defer { bytes.task.cancel() }
            let limit = 5 * 1024 * 1024
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit else {
                throw MiningError.message("The generated audio could not be downloaded. Please retry.")
            }
            var audio = Data()
            for try await byte in bytes {
                guard audio.count < limit else { throw MiningError.message("The generated audio could not be downloaded. Please retry.") }
                audio.append(byte)
            }
            guard !audio.isEmpty else { throw MiningError.message("The generated audio could not be downloaded. Please retry.") }
            try Task.checkCancellation()
            return audio
        } catch {
            if let predictionID, predictionPending {
                let client = self
                _ = await Task.detached {
                    var request = client.authorized(client.api.appendingPathComponent("predictions/\(predictionID)/cancel"), token: token)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 5
                    _ = try? await client.session.data(for: request)
                }.value
            }
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? MiningError { throw error }
            throw MiningError.message("Could not connect to Replicate. Check your connection and retry.")
        }
    }

    private func authorized(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func fetchPrediction(_ request: URLRequest) async throws -> Prediction {
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200, 201: return try JSONDecoder().decode(Prediction.self, from: data)
        case 401, 403: throw MiningError.message("Replicate rejected the API key. Replace it in Settings.")
        case 402: throw MiningError.message("Add credit to your Replicate account to generate word audio.")
        case 429: throw MiningError.message("Replicate is busy. Please retry shortly.")
        default: throw MiningError.message("Replicate could not generate word audio. Please retry.")
        }
    }
}
