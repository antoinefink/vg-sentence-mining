import AVFoundation
import AppKit
import Foundation

public struct Screenshot: Identifiable {
    public let id = UUID()
    public let date: Date
    public let url: URL
}

/// Owns only this app's temporary captures. Exported media belongs to Anki.
@MainActor public final class SessionMedia {
    private struct AudioChunk {
        let start: Double
        let count: Int
        let url: URL
        var end: Double { start + Double(count) / 16000 }
    }
    public private(set) var screenshots: [Screenshot] = []
    private var chunks: [AudioChunk] = []
    private var pending: [Float] = []
    private var sampleCount = 0
    private let root: URL
    public private(set) var sessionStart: Date?
    private var previewExpiresAt: Date?

    static func captureDirectory(in temporaryDirectory: URL, bundleIdentifier: String) -> URL {
        temporaryDirectory.appendingPathComponent("VG-Sentence-Mining-Captures", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static func removeLegacyCaptures(in temporaryDirectory: URL, bundleIdentifier: String, anotherMainAppIsRunning: Bool) throws {
        guard bundleIdentifier == "io.antoine.vg-sentence-mining", !anotherMainAppIsRunning else { return }
        let legacyRoot = temporaryDirectory.appendingPathComponent("VG-Sentence-Mining-Captures", isDirectory: true)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try FileManager.default.removeItem(at: entry)
            }
        }
    }

    public init(bufferDirectory: URL? = nil) throws {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.antoine.vg-sentence-mining"
        if bufferDirectory == nil {
            let anotherMainAppIsRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            guard !anotherMainAppIsRunning else {
                throw MiningError.message("Another copy of this app is running. Use its existing window before opening a second copy.")
            }
            try Self.removeLegacyCaptures(in: FileManager.default.temporaryDirectory, bundleIdentifier: bundleIdentifier,
                                          anotherMainAppIsRunning: anotherMainAppIsRunning)
        }
        let parent = bufferDirectory ?? Self.captureDirectory(
            in: FileManager.default.temporaryDirectory,
            bundleIdentifier: bundleIdentifier
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: old)
        }
        root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func reset() throws {
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        screenshots.removeAll(); chunks.removeAll(); pending.removeAll(); sampleCount = 0; sessionStart = nil
        previewExpiresAt = nil
    }

    public func addScreenshot(_ data: Data, date: Date) throws {
        let url = root.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        screenshots.append(Screenshot(date: date, url: url))
    }

    public func appendAudio(_ samples: [Float], date: Date) throws {
        if sessionStart == nil { sessionStart = date }
        pending.append(contentsOf: samples)
        while pending.count >= 16000 {
            let audio = Array(pending.prefix(16000))
            try writeChunk(audio)
            pending.removeFirst(16000)
        }
    }

    public func flush() throws {
        if !pending.isEmpty { try writeChunk(pending); pending.removeAll() }
    }

    private func writeChunk(_ samples: [Float]) throws {
        let url = root.appendingPathComponent("\(sampleCount).pcm")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
        chunks.append(AudioChunk(start: Double(sampleCount) / 16000, count: samples.count, url: url))
        sampleCount += samples.count
    }

    public func expire(now: Date) throws {
        let cutoff = now.addingTimeInterval(-1800)
        for frame in screenshots where frame.date <= cutoff { try FileManager.default.removeItem(at: frame.url) }
        screenshots.removeAll { $0.date <= cutoff }
        if let sessionStart {
            let seconds = cutoff.timeIntervalSince(sessionStart)
            for chunk in chunks where chunk.end <= seconds { try FileManager.default.removeItem(at: chunk.url) }
            chunks.removeAll { $0.end <= seconds }
            if Double(sampleCount + pending.count) / 16000 <= seconds {
                sampleCount += pending.count
                pending.removeAll()
            }
        }
        if let previewExpiresAt, previewExpiresAt <= now { try clearPreview() }
    }

    public func nearbyScreenshots(at date: Date) -> [Screenshot] {
        screenshots.filter { abs($0.date.timeIntervalSince(date)) <= 4 }.sorted { $0.date < $1.date }
    }

    public func audioClip(start: Double, end: Double, now: Date = Date()) throws -> URL {
        guard let sessionStart, sessionStart.addingTimeInterval(start + 1800) > now, end > start else {
            throw MiningError.message("This sentence has expired from the 30-minute buffer.")
        }
        try flush()
        let availableEnd = Double(sampleCount) / 16000
        let lower = max(0, start)
        let upper = min(end, availableEnd)
        var samples: [Float] = []
        for chunk in chunks where chunk.end > lower && chunk.start < upper {
            let data = try Data(contentsOf: chunk.url)
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let from = max(0, Int(((lower - chunk.start) * 16000).rounded()))
            let to = min(floats.count, Int(((upper - chunk.start) * 16000).rounded()))
            if from < to { samples.append(contentsOf: floats[from..<to]) }
        }
        guard !samples.isEmpty else { throw MiningError.message("The audio clip is no longer available.") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count) }
        let url = root.appendingPathComponent("preview.wav")
        let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        try output.write(from: buffer)
        previewExpiresAt = sessionStart.addingTimeInterval(start + 1800)
        return url
    }

    public func clearPreview() throws {
        let url = root.appendingPathComponent("preview.wav")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        previewExpiresAt = nil
    }
}
