@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import MiningCore

/// A bounded, overlapping recognition window. Only the selected language is decoded.
public actor LocalSpeechEngine {
    private var recognizer: AsrManager?
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
        let models = try await AsrModels.downloadAndLoad(to: modelDirectory.appendingPathComponent("Transcription"), version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let speakers = LSEENDDiarizer()
        try await speakers.initialize(variant: .dihard3, cacheDirectory: modelDirectory.appendingPathComponent("Speakers"))
        recognizer = manager
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

    public func append(_ audio: [Float]) async throws -> [SpokenWord] {
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
        guard samples.count >= rate * 4, sinceRecognition >= rate * 2 else { return [] }
        sinceRecognition = 0
        return try await recognize(final: false)
    }

    public func finish() async throws -> [SpokenWord] {
        _ = try diarizer?.finalizeSession()
        let words = try await recognize(final: true)
        samples.removeAll()
        return words
    }

    private func recognize(final: Bool) async throws -> [SpokenWord] {
        guard let recognizer, let diarizer, !samples.isEmpty else { return [] }
        let window = samples
        let start = Double(totalSamples - window.count) / Double(rate)
        let cutoff = Double(totalSamples) / Double(rate) - (final ? 0 : 0.5)
        var decoder = TdtDecoderState.make(decoderLayers: await recognizer.decoderLayerCount)
        let result = try await recognizer.transcribe(window, decoderState: &decoder, language: language == .german ? .german : .spanish)
        let segments = diarizer.timeline.speakers.values.flatMap { $0.finalizedSegments + $0.tentativeSegments }
        var words: [SpokenWord] = []
        for timing in buildWordTimings(from: result.tokenTimings ?? []) {
            let wordStart = start + timing.startTime
            let wordEnd = start + timing.endTime
            let overlapping = segments.map { segment in
                (segment.speakerIndex, max(0, min(wordEnd, diarizerOffset + Double(segment.endTime)) - max(wordStart, diarizerOffset + Double(segment.startTime))))
            }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
            let nearest = segments.map { segment in
                (segment.speakerIndex, max(0, max(diarizerOffset + Double(segment.startTime) - wordEnd, wordStart - diarizerOffset - Double(segment.endTime))))
            }.filter { $0.1 <= 0.6 }.min { $0.1 < $1.1 }
            words.append(SpokenWord(text: timing.word, start: wordStart, end: wordEnd, speaker: overlapping?.0 ?? nearest?.0))
        }
        return stitcher.append(words, through: cutoff)
    }
}
