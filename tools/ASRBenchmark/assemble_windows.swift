import Foundation

@main struct AssembleWindows {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("results"), includingPropertiesForKeys: nil)
        var models: [String: [[String: Any]]] = [:]
        for file in files where file.lastPathComponent.hasPrefix("windows-") && file.pathExtension == "json" {
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            guard record["status"] as? String == "ok", let model = record["model"] as? String else { continue }
            models[model, default: []].append(record)
        }
        let destination = root.appendingPathComponent("assembly")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (model, records) in models {
            var stitcher = WindowStitcher()
            var assembler = TranscriptAssembler()
            var trace: [[String: Any]] = []
            var lastWords: [SpokenWord] = []
            var lastEnd = 0.0
            for record in records.sorted(by: { ($0["window_end"] as! Double) < ($1["window_end"] as! Double) }) {
                let end = record["window_end"] as! Double
                let duration = record["audio_seconds"] as! Double
                let start = end - duration
                let words = (record["words"] as! [[String: Any]]).compactMap { raw -> SpokenWord? in
                    let wordStart = max(0, raw["start"] as! Double)
                    let wordEnd = min(duration, raw["end"] as! Double)
                    let text = (raw["text"] as! String).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, wordEnd > wordStart else { return nil }
                    return SpokenWord(text: text, start: start + wordStart, end: start + wordEnd)
                }
                let emitted = stitcher.append(words, through: end - 0.5)
                assembler.append(emitted, sessionStart: Date(timeIntervalSince1970: 0), language: .german)
                trace.append(["window_end": end, "raw_text": record["text"] as! String,
                              "emitted_text": emitted.map(\.text).joined(separator: " "), "inference_seconds": record["inference_seconds"] as! Double])
                lastWords = words
                lastEnd = end
            }
            assembler.append(stitcher.append(lastWords, through: lastEnd), sessionStart: Date(timeIntervalSince1970: 0), language: .german)
            let text = assembler.rows.map(\.text).joined(separator: " ")
            let payload: [String: Any] = ["model": model, "text": text, "rows": assembler.rows.map(\.text), "trace": trace,
                                          "note": "Offline replay through unchanged production word clipping, WindowStitcher and TranscriptAssembler; no actual capture-to-display latency measured."]
            let output = destination.appendingPathComponent("\(model).json")
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            print("\(model): \(text)")
        }
    }
}
