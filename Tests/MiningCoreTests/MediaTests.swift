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
