import AVFoundation
import Foundation
import MiningCore
import MiningSpeech

@main struct SpeechProbe {
    private struct ObservedWord: Encodable {
        let text: String
        let start: Double
        let end: Double
        let speaker: Int?
        let arrival: Double
        let latency: Double
    }

    private struct Report: Encodable {
        struct Sentence: Encodable {
            let text: String
            let start: Double
            let end: Double
            let speaker: Int?
        }
        let source: String
        let language: String
        let realtime: Bool
        let packetMilliseconds: Int
        let audioSeconds: Double
        let elapsedSeconds: Double
        let inferenceSeconds: Double
        let medianLatencySeconds: Double
        let p95LatencySeconds: Double
        let maxLatencySeconds: Double
        let speakers: [Int]
        let words: [ObservedWord]
        let sentences: [Sentence]
    }

    static func main() async throws {
        let engine = LocalSpeechEngine()
        let root = URL(fileURLWithPath: "/Volumes/T9/VG Sentence Mining/Models", isDirectory: true)
        let loadStart = Date()
        try await engine.prepare(modelDirectory: root)
        print("Models loaded in \(Date().timeIntervalSince(loadStart)) seconds from \(root.path)")
        guard CommandLine.arguments.count > 1, CommandLine.arguments[1] != "--prepare" else { return }
        let language = CommandLine.arguments.count > 2 ? GameLanguage(rawValue: CommandLine.arguments[2]) ?? .german : .german
        let glossary: [String]
        if let flag = CommandLine.arguments.firstIndex(of: "--glossary"), CommandLine.arguments.indices.contains(flag + 1) {
            glossary = GameGlossary(text: try String(contentsOfFile: CommandLine.arguments[flag + 1], encoding: .utf8)).terms
        } else { glossary = [] }
        await engine.start(language: language)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let converter = AVAudioConverter(from: source.format, to: format)!
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * 16000 / source.format.sampleRate) + 1024)!
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        if let conversionError { throw conversionError }
        let audio = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        if CommandLine.arguments.contains("--batch") {
            let words = try await engine.transcribe(audio, language: language, glossary: glossary)
            print("BATCH: \(words.map(\.text).joined(separator: " "))")
            if CommandLine.arguments.contains("--words") { for word in words { print("\(word.start)-\(word.end) \(word.text)") } }
            return
        }
        let start = Date()
        let realtime = CommandLine.arguments.contains("--realtime")
        let packetFlag = CommandLine.arguments.firstIndex(of: "--packet-ms")
        let packetMilliseconds = packetFlag.flatMap { flag in
            CommandLine.arguments.indices.contains(flag + 1) ? Int(CommandLine.arguments[flag + 1]) : nil
        } ?? 500
        guard (1...1000).contains(packetMilliseconds) else { throw MiningError.message("--packet-ms must be between 1 and 1000.") }
        let packetSamples = 16 * packetMilliseconds
        var observed: [ObservedWord] = []
        var inferenceSeconds: Double = 0
        var assembler = TranscriptAssembler()
        for offset in stride(from: 0, to: audio.count, by: packetSamples) {
            let end = min(offset + packetSamples, audio.count)
            let inputSeconds = Double(end) / 16000
            if realtime {
                let wait = inputSeconds - Date().timeIntervalSince(start)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            }
            let inferenceStart = Date()
            let words = try await engine.append(Array(audio[offset..<end]), glossary: glossary)
            let processingSeconds = Date().timeIntervalSince(inferenceStart)
            inferenceSeconds += processingSeconds
            let arrival = realtime ? Date().timeIntervalSince(start) : inputSeconds + processingSeconds
            observed.append(contentsOf: words.map {
                ObservedWord(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker, arrival: arrival, latency: max(0, arrival - $0.end))
            })
            if CommandLine.arguments.contains("--words") { for word in words { print("WINDOW \(offset / 16000): \(word.start)-\(word.end) \(word.text)") } }
            assembler.append(words, sessionStart: start, language: language)
        }
        let finishStart = Date()
        let finalWords = try await engine.finish(glossary: glossary)
        let finishSeconds = Date().timeIntervalSince(finishStart)
        inferenceSeconds += finishSeconds
        let finalArrival = realtime ? Date().timeIntervalSince(start) : Double(audio.count) / 16000 + finishSeconds
        observed.append(contentsOf: finalWords.map {
            ObservedWord(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker, arrival: finalArrival, latency: max(0, finalArrival - $0.end))
        })
        assembler.append(finalWords, sessionStart: start, language: language)
        for row in assembler.rows { print("[\(String(format: "%.2f", row.start))] Speaker \(row.speaker.map { String($0 + 1) } ?? "?"): \(row.text)") }
        print("Processed \(Double(audio.count) / 16000)s audio in \(Date().timeIntervalSince(start))s")
        if let flag = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(flag + 1) {
            let latencies = observed.map(\.latency).sorted()
            func percentile(_ value: Double) -> Double {
                latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * value))]
            }
            let report = Report(
                source: CommandLine.arguments[1], language: language.rawValue, realtime: realtime, packetMilliseconds: packetMilliseconds,
                audioSeconds: Double(audio.count) / 16000, elapsedSeconds: Date().timeIntervalSince(start), inferenceSeconds: inferenceSeconds,
                medianLatencySeconds: percentile(0.5), p95LatencySeconds: percentile(0.95), maxLatencySeconds: latencies.last ?? 0,
                speakers: Array(Set(observed.compactMap(\.speaker))).sorted(), words: observed,
                sentences: assembler.rows.map { .init(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker) }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), options: .atomic)
            print("Words: \(observed.count); speakers: \(report.speakers.count); median latency: \(report.medianLatencySeconds)s; p95: \(report.p95LatencySeconds)s")
        }
    }
}
