import AVFoundation
import Foundation
import Testing
@testable import MiningCore

@Test @MainActor func extractsOriginalSamplesAcrossDiskChunksAndExpiresMedia() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vg-media-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let media = try SessionMedia(bufferDirectory: directory)
    let date = Date(timeIntervalSince1970: 1000)
    let first = Array(repeating: Float(0.25), count: 16000)
    let second = Array(repeating: Float(-0.25), count: 16000)
    try media.appendAudio(first + second, date: date)
    try media.addScreenshot(Data([1, 2, 3]), date: date)
    let frame = try #require(media.screenshots.first)
    let clip = try media.audioClip(start: 0.5, end: 1.5, now: date.addingTimeInterval(2))
    let file = try AVAudioFile(forReading: clip)
    #expect(file.length == 16000)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)!
    try file.read(into: buffer)
    #expect(abs(buffer.floatChannelData![0][0] - 0.25) < 0.001)
    #expect(abs(buffer.floatChannelData![0][15999] + 0.25) < 0.001)
    try media.expire(now: date.addingTimeInterval(1802))
    #expect(media.screenshots.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: frame.url.path))
    #expect(!FileManager.default.fileExists(atPath: clip.path))
    #expect(throws: MiningError.self) { try media.audioClip(start: 0, end: 1, now: date.addingTimeInterval(1802)) }
}

@Test @MainActor func expiresUnflushedAudioAfterInterruptedCapture() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vg-pending-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let media = try SessionMedia(bufferDirectory: directory)
    let date = Date(timeIntervalSince1970: 1000)
    try media.appendAudio(Array(repeating: Float(0.25), count: 8000), date: date)
    try media.expire(now: date.addingTimeInterval(1801))
    try media.flush()
    let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!.allObjects as! [URL]
    #expect(files.filter { $0.pathExtension == "pcm" }.isEmpty)
}

@Test @MainActor func previewCleanupCannotDeleteAnotherAppBundlesMedia() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vg-isolation-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installed = try SessionMedia(bufferDirectory: SessionMedia.captureDirectory(in: directory, bundleIdentifier: "installed"))
    let date = Date(timeIntervalSince1970: 1000)
    try installed.addScreenshot(Data([1]), date: date)
    let installedFrame = try #require(installed.screenshots.first?.url)
    let previewDirectory = SessionMedia.captureDirectory(in: directory, bundleIdentifier: "preview")
    let preview = try SessionMedia(bufferDirectory: previewDirectory)
    try preview.addScreenshot(Data([2]), date: date)
    let previewFrame = try #require(preview.screenshots.first?.url)
    _ = try SessionMedia(bufferDirectory: previewDirectory)
    #expect(FileManager.default.fileExists(atPath: installedFrame.path))
    #expect(!FileManager.default.fileExists(atPath: previewFrame.path))
}

@Test @MainActor func migratesLegacyCapturesOnlyFromTheMainAppWithoutAnotherRunningCopy() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vg-legacy-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("VG-Sentence-Mining-Captures")
    let legacy = root.appendingPathComponent(UUID().uuidString)
    let preview = SessionMedia.captureDirectory(in: directory, bundleIdentifier: "preview")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    try Data([1]).write(to: legacy.appendingPathComponent("recording.pcm"))
    try SessionMedia.removeLegacyCaptures(in: directory, bundleIdentifier: "preview", anotherMainAppIsRunning: false)
    #expect(FileManager.default.fileExists(atPath: legacy.path))
    try SessionMedia.removeLegacyCaptures(in: directory, bundleIdentifier: "io.antoine.vg-sentence-mining", anotherMainAppIsRunning: true)
    #expect(FileManager.default.fileExists(atPath: legacy.path))
    try SessionMedia.removeLegacyCaptures(in: directory, bundleIdentifier: "io.antoine.vg-sentence-mining", anotherMainAppIsRunning: false)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(atPath: preview.path))
}
