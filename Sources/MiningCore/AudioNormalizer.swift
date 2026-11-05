import AVFoundation
import Foundation

enum AudioNormalizer {
    static func normalizedWAV(_ data: Data) throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vg-normalize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let input = root.appendingPathComponent("input.audio")
            try data.write(to: input)
            let file = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
            let channels = Int(file.processingFormat.channelCount)
            guard channels > 0, file.length > 0, file.length <= 32_000_000 / channels,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw MiningError.message("The audio is empty or too large to prepare for Anki.")
            }
            try file.read(into: buffer)
            try normalize(buffer)
            let output = root.appendingPathComponent("normalized.wav")
            do {
                let writer = try AVAudioFile(forWriting: output, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ])
                try writer.write(from: buffer)
            }
            return try Data(contentsOf: output)
        } catch let error as MiningError { throw error }
        catch { throw MiningError.message("The audio could not be prepared for Anki. Retry the audio, then send the card again.") }
    }

    private static func normalize(_ buffer: AVAudioPCMBuffer) throws {
        guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw MiningError.message("The audio could not be read for Anki.")
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let blockSize = max(1, Int(buffer.format.sampleRate * 0.05))
        var blocks: [(energy: Double, count: Int)] = []
        var peak = 0.0
        for start in stride(from: 0, to: frames, by: blockSize) {
            let end = min(start + blockSize, frames)
            var energy = 0.0
            for channel in 0..<channels {
                for index in start..<end {
                    let value = Double(samples[channel][index])
                    guard value.isFinite else { throw MiningError.message("The audio contains invalid samples. Retry the audio before sending the card.") }
                    peak = max(peak, abs(value))
                    energy += value * value
                }
            }
            blocks.append((energy, (end - start) * channels))
        }
        let loudest = blocks.map { $0.energy / Double($0.count) }.max() ?? 0
        let gate = max(0.00001, loudest * 0.01)
        let active = blocks.filter { $0.energy / Double($0.count) >= gate }
        let energy = active.reduce(0) { $0 + $1.energy }
        let count = active.reduce(0) { $0 + $1.count }
        let rms = count > 0 ? sqrt(energy / Double(count)) : 0
        let requestedGain = rms > 0 ? min(10, 0.1 / rms) : 1
        let gain = Float(peak > 0 ? min(requestedGain, pow(10, -1.0 / 20) / peak) : 1)
        for channel in 0..<channels {
            for index in 0..<frames { samples[channel][index] *= gain }
        }
    }
}
