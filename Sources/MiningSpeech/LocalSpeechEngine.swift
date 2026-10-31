@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
@preconcurrency import WhisperKit
import Foundation
import MiningCore

/// A bounded, overlapping recognition window. Only the selected language is decoded.
public actor LocalSpeechEngine {
    public static let modelName = "openai_whisper-large-v3-v20240930_turbo"
    private var recognizer: WhisperKit?
    private var promptGlossary: [String] = []
    private var promptTokens: [Int]?
    private var diarizer: LSEENDDiarizer?
    private var samples: [Float] = []
    private var totalSamples = 0
    private var sinceRecognition = 0
    private var stitcher = WindowStitcher()
    private var diarizerOffset: Double = 0
    private var language: GameLanguage = .german
    private let rate = 16000

    public init() {}

    public func prepare(modelDirectory: URL) async throws {
        guard FileManager.default.fileExists(atPath: "/Volumes/T9") else {
            throw MiningError.message("Connect the T9 drive before loading speech models.")
        }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let manager = try await WhisperKit(WhisperKitConfig(
            model: Self.modelName,
            downloadBase: modelDirectory.appendingPathComponent("Whisper"),
            tokenizerFolder: modelDirectory.appendingPathComponent("Whisper"),
            segmentSeeker: GlossarySegmentSeeker(),
            verbose: false, prewarm: true, load: true
        ))
        let speakers = LSEENDDiarizer()
        try await speakers.initialize(variant: .dihard3, cacheDirectory: modelDirectory.appendingPathComponent("Speakers"))
        recognizer = manager
        promptGlossary = []; promptTokens = nil
        diarizer = speakers
    }

    public func start(language: GameLanguage) {
        self.language = language
        discardSession()
    }

    public func discardSession() {
        samples.removeAll(); totalSamples = 0; sinceRecognition = 0
        stitcher = WindowStitcher(); diarizerOffset = 0
        diarizer?.reset()
    }

    public func ingest(_ audio: [Float]) throws {
        guard let diarizer, recognizer != nil else { throw MiningError.message("Load the local models first.") }
        samples.append(contentsOf: audio)
        totalSamples += audio.count
        sinceRecognition += audio.count
        if Double(totalSamples) / Double(rate) - diarizerOffset >= 1800 {
            diarizer.reset()
            diarizerOffset = Double(totalSamples - audio.count) / Double(rate)
        }
        try diarizer.addAudio(audio, sourceSampleRate: Double(rate))
        _ = try diarizer.process()
        if samples.count > rate * 8 { samples.removeFirst(samples.count - rate * 8) }
    }

    public func recognizePending(glossary: [String] = []) async throws -> [SpokenWord] {
        guard samples.count >= rate * 4, sinceRecognition >= rate * 2 else { return [] }
        sinceRecognition = 0
        return try await recognize(final: false, glossary: glossary)
    }

    public func finish(glossary: [String] = []) async throws -> [SpokenWord] {
        _ = try diarizer?.finalizeSession()
        let words = try await recognize(final: true, glossary: glossary)
        samples.removeAll()
        return words
    }

    public func transcribe(_ audio: [Float], language: GameLanguage, glossary: [String] = []) async throws -> [SpokenWord] {
        guard let recognizer, let tokenizer = recognizer.tokenizer else { throw MiningError.message("Load the local speech models first.") }
        guard audio.contains(where: { abs($0) > 0.00001 }) else { return [] }
        if glossary != promptGlossary {
            promptGlossary = glossary
            promptTokens = glossary.isEmpty ? nil : tokenizer.encode(text: " " + glossary.joined(separator: ", "))
        }
        let options = DecodingOptions(
            language: language.rawValue,
            temperatureFallbackCount: 1,
            skipSpecialTokens: true,
            wordTimestamps: true,
            windowClipTime: 0,
            promptTokens: promptTokens,
            suppressBlank: true
        )
        let results = try await recognizer.transcribe(audioArray: audio, decodeOptions: options)
        let duration = Double(audio.count) / Double(rate)
        return results.flatMap(\.segments).flatMap { $0.words ?? [] }.compactMap { word in
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = max(0, Double(word.start)), end = min(duration, Double(word.end))
            guard !text.isEmpty, end > start else { return nil }
            return SpokenWord(text: text, start: start, end: end, speaker: nil)
        }
    }

    private func recognize(final: Bool, glossary: [String]) async throws -> [SpokenWord] {
        guard let diarizer, !samples.isEmpty else { return [] }
        let window = samples
        let start = Double(totalSamples - window.count) / Double(rate)
        let cutoff = Double(totalSamples) / Double(rate) - (final ? 0 : 0.5)
        let segments = diarizer.timeline.speakers.values.flatMap { $0.finalizedSegments + $0.tentativeSegments }
        let speakerOffset = diarizerOffset
        let decoded = try await transcribe(window, language: language, glossary: glossary)
        var words: [SpokenWord] = []
        for timing in decoded {
            let wordStart = start + timing.start
            let wordEnd = start + timing.end
            let overlapping = segments.map { segment in
                (segment.speakerIndex, max(0, min(wordEnd, speakerOffset + Double(segment.endTime)) - max(wordStart, speakerOffset + Double(segment.startTime))))
            }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
            let nearest = segments.map { segment in
                (segment.speakerIndex, max(0, max(speakerOffset + Double(segment.startTime) - wordEnd, wordStart - speakerOffset - Double(segment.endTime))))
            }.filter { $0.1 <= 0.6 }.min { $0.1 < $1.1 }
            words.append(SpokenWord(text: timing.text, start: wordStart, end: wordEnd, speaker: overlapping?.0 ?? nearest?.0))
        }
        return stitcher.append(words, through: cutoff)
    }
}
