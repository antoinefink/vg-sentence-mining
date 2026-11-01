import AVFoundation
import Foundation
import MiningCore
import MiningSpeech
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["VG_SPEECH_INTEGRATION"] == "1"))
func selectableModelsRecognizeGermanAndSpanishWithValidWordTimings() async throws {
    let engine = LocalSpeechEngine()
    let terms = GameGlossary(text: "Geralt\nGeralt von Riva\nGeralt de Rivia\nYennefer\nKaer Morhen\nCiri\nVesemir").terms
    for model in TranscriptionModel.allCases {
        try await engine.prepare(modelDirectory: URL(fileURLWithPath: "/Volumes/T9/VG Sentence Mining/Models"), model: model)
        for (fixture, language) in [("german", GameLanguage.german), ("spanish", GameLanguage.spanish)] {
            let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "wav", subdirectory: "Fixtures"))
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channel = try #require(buffer.floatChannelData?[0])
            let audio = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let baseline = try await engine.transcribe(audio, language: language)
            let words = try await engine.transcribe(audio, language: language, glossary: terms)
            let text = words.map(\.text).joined(separator: " ")
            #expect(!words.isEmpty)
            if model.supportsGlossary {
                for term in ["Geralt", "Yennefer", "Kaer Morhen", "Ciri", "Vesemir"] { #expect(text.contains(term), "\(model.name): \(text)") }
            }
            if let directory = ProcessInfo.processInfo.environment["VG_SPEECH_REPORT_DIRECTORY"] {
                let report: [String: Any] = ["model": model.rawValue, "language": language.rawValue, "text": text,
                    "words": words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }]
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(model.rawValue)-\(fixture).json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .withoutOverwriting)
            }
            #expect(words.allSatisfy { $0.end > $0.start && $0.start >= 0 && $0.end <= Double(audio.count) / 16000 + 0.1 })
            for (previous, next) in zip(words, words.dropFirst()) { #expect(next.start >= previous.start) }
            _ = try await engine.transcribe(audio, language: language, glossary: ["Über-Erde", "Terminiden"])
            let cleared = try await engine.transcribe(audio, language: language)
            #expect(Array(cleared.prefix(6).map(\.text)) == Array(baseline.prefix(6).map(\.text)))
            let restored = try await engine.transcribe(audio, language: language, glossary: terms)
            if model.supportsGlossary { #expect(restored.map(\.text).joined(separator: " ").contains("Yennefer")) }
            let silence = try await engine.transcribe(Array(repeating: Float(0), count: 8 * 16000), language: language, glossary: terms)
            #expect(silence.isEmpty)
            var seed: UInt64 = 17
            let noise: [Float] = (0..<(8 * 16000)).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * 0.08
            }
            let background = try await engine.transcribe(noise, language: language, glossary: terms)
            #expect(background.isEmpty)
            let quiet = try await engine.transcribe(audio.map { $0 * 0.15 }, language: language, glossary: terms)
            #expect(!quiet.isEmpty)
            #expect(quiet.count >= words.count - 2)
            let followedByNoise = try await engine.transcribe(audio + noise, language: language, glossary: terms)
            #expect(!followedByNoise.isEmpty)
            if let directory = ProcessInfo.processInfo.environment["VG_SPEECH_REPORT_DIRECTORY"] {
                let report: [String: Any] = ["model": model.rawValue, "language": language.rawValue,
                    "quiet": quiet.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] },
                    "background": background.map(\.text),
                    "speechThenNoise": followedByNoise.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }]
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(model.rawValue)-\(fixture)-noise-quiet.json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .withoutOverwriting)
            }
            #expect(followedByNoise.count <= words.count + 2)
            #expect(followedByNoise.allSatisfy { $0.end <= Double(audio.count) / 16000 + 1.5 }, "\(model.name) \(language): \(followedByNoise.map { "\($0.text)@\($0.start)-\($0.end)" })")
        }
    }
    await engine.unload()
}
