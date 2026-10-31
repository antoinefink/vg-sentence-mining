import AVFoundation
import Foundation
import MiningCore
import MiningSpeech
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["VG_SPEECH_INTEGRATION"] == "1"))
func glossaryNamesKeepTheirWordTimingsInGermanAndSpanish() async throws {
    let engine = LocalSpeechEngine()
    try await engine.prepare(modelDirectory: URL(fileURLWithPath: "/Volumes/T9/VG Sentence Mining/Models"))
    let terms = GameGlossary(text: "Geralt\nGeralt von Riva\nGeralt de Rivia\nYennefer\nKaer Morhen\nCiri\nVesemir").terms
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
        for term in ["Geralt", "Yennefer", "Kaer Morhen", "Ciri", "Vesemir"] { #expect(text.contains(term)) }
        #expect(words.allSatisfy { $0.end > $0.start && $0.start >= 0 && $0.end <= Double(audio.count) / 16000 + 0.1 })
        for (previous, next) in zip(words, words.dropFirst()) { #expect(next.start >= previous.start) }
        _ = try await engine.transcribe(audio, language: language, glossary: ["Über-Erde", "Terminiden"])
        let cleared = try await engine.transcribe(audio, language: language)
        #expect(Array(cleared.prefix(6).map(\.text)) == Array(baseline.prefix(6).map(\.text)))
        let restored = try await engine.transcribe(audio, language: language, glossary: terms)
        #expect(restored.map(\.text).joined(separator: " ").contains("Yennefer"))
        let silence = try await engine.transcribe(Array(repeating: Float(0), count: 8 * 16000), language: language, glossary: terms)
        #expect(silence.isEmpty)
    }
}
