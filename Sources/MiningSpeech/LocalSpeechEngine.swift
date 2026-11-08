@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import MiningCore

/// A bounded, overlapping recognition window. Only the selected language is decoded.
public actor LocalSpeechEngine {
    private var recognizer: SpeechWorker?
    private var diarizer: LSEENDDiarizer?
    private var voiceActivity: VadManager?
    private var audioBuffer = RecognitionAudioBuffer()
    private var stitcher = WindowStitcher()
    private var diarizerOffset: Double = 0
    private var language: GameLanguage = .german
    private var preparedModelDirectory: URL?
    private let rate = 16000

    public init() {}

    public func prepare(modelDirectory: URL, model: TranscriptionModel = .parakeetUltra) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MiningError.message("The models folder is unavailable. In Settings, choose the speech folder containing Models and SpeechRuntime.")
        }
        await unload()
        if preparedModelDirectory != modelDirectory.standardizedFileURL {
            voiceActivity = nil
            diarizer = nil
            preparedModelDirectory = modelDirectory.standardizedFileURL
        }
        let runtime = modelDirectory.deletingLastPathComponent().appendingPathComponent("SpeechRuntime", isDirectory: true)
        let worker = try SpeechWorker(runtime: runtime, models: modelDirectory, model: model)
        do {
            try await worker.start()
            if voiceActivity == nil {
                voiceActivity = try await VadManager(config: VadConfig(defaultThreshold: SpeechActivityFilter.threshold, computeUnits: .cpuOnly),
                                                     modelDirectory: modelDirectory.appendingPathComponent("SpeechDetection"))
            }
            if diarizer == nil {
                let speakers = LSEENDDiarizer()
                try await speakers.initialize(variant: .dihard3, cacheDirectory: modelDirectory.appendingPathComponent("Speakers"))
                diarizer = speakers
            }
            recognizer = worker
        } catch {
            await worker.shutdown()
            throw error
        }
    }

    public func unload() async {
        if let recognizer { await recognizer.shutdown() }
        recognizer = nil
        discardSession()
    }

    public func start(language: GameLanguage) {
        self.language = language
        discardSession()
    }

    public func discardSession() {
        audioBuffer.reset()
        stitcher = WindowStitcher(); diarizerOffset = 0
        diarizer?.reset()
    }

    public func ingest(_ audio: [Float]) throws {
        guard let diarizer, recognizer != nil else { throw MiningError.message("Load the local models first.") }
        try audioBuffer.append(audio)
        if Double(audioBuffer.totalSamples) / Double(rate) - diarizerOffset >= 1800 {
            diarizer.reset()
            diarizerOffset = Double(audioBuffer.totalSamples - audio.count) / Double(rate)
        }
        try diarizer.addAudio(audio, sourceSampleRate: Double(rate))
        _ = try diarizer.process()
    }

    public func recognizePending(glossary: [String] = []) async throws -> [SpokenWord] {
        guard let window = audioBuffer.next() else { return [] }
        let words = try await recognize(window, glossary: glossary)
        audioBuffer.acknowledge(window)
        return words
    }

    public func finish(glossary: [String] = []) async throws -> [SpokenWord] {
        _ = try diarizer?.finalizeSession()
        var words: [SpokenWord] = []
        while let window = audioBuffer.next(final: true) {
            words += try await recognize(window, glossary: glossary)
            audioBuffer.acknowledge(window)
        }
        audioBuffer.reset()
        return words
    }

    public func transcribe(_ audio: [Float], language: GameLanguage, glossary: [String] = []) async throws -> [SpokenWord] {
        guard let recognizer, let voiceActivity else { throw MiningError.message("Load the local speech models first.") }
        guard !audio.isEmpty else { return [] }
        guard audio.count <= rate * 32 else { throw MiningError.message("Transcribe at most 32 seconds at a time.") }
        guard audio.contains(where: { abs($0) > 0.00001 }) else { return [] }
        let probabilities = try await voiceActivity.process(audio).map(\.probability)
        let activity = SpeechActivityFilter(probabilities: probabilities, duration: Double(audio.count) / Double(rate))
        guard let range = activity.sampleRange else { return [] }
        let offset = Double(range.lowerBound) / Double(rate)
        let words = try await recognizer.transcribe(Array(audio[range]), language: language, glossary: glossary)
        return words.map { SpokenWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker) }
            .filter { activity.contains($0) }
    }

    private func recognize(_ window: RecognitionAudioBuffer.Window, glossary: [String]) async throws -> [SpokenWord] {
        guard let diarizer else { return [] }
        let start = Double(window.startSample) / Double(rate)
        let cutoff = Double(window.endSample) / Double(rate) - (window.isFinal ? 0 : 0.5)
        let segments = diarizer.timeline.speakers.values.flatMap { $0.finalizedSegments + $0.tentativeSegments }
        let speakerOffset = diarizerOffset
        let decoded = try await transcribe(window.samples, language: language, glossary: glossary)
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
