import AVFoundation
import Foundation
import Testing
@testable import MiningCore

struct AudioFixture {
    static func wave(amplitude: Float, rate: Double = 16000, channels: Int = 1, padding: Int = 0, spike: Bool = false) throws -> Data {
        let count = Int(rate)
        var samples = (0..<count).map { amplitude * Float(sin(2 * .pi * 400 * Double($0) / rate)) }
        if spike { samples[count / 2] = 0.99 }
        samples = Array(repeating: Float(0), count: padding) + samples
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<channels {
            for index in samples.indices { buffer.floatChannelData![channel][index] = samples[index] * (channel == 0 ? 1 : 0.5) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    static func read(_ data: Data) throws -> (channels: [[Float]], rate: Double) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channels = (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
        return (channels, file.fileFormat.sampleRate)
    }

    static func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
}

struct AudioNormalizationTests {
    @Test func matchesQuietAndLoudRecordingsToACommonLevel() throws {
        for amplitude: Float in [0.02, 0.6] {
            let result = try AudioFixture.read(AudioNormalizer.normalizedWAV(AudioFixture.wave(amplitude: amplitude)))
            #expect(abs(AudioFixture.rms(result.channels[0]) - 0.1) < 0.002)
            #expect(result.channels[0].count == 16000)
        }
    }

    @Test func silencePaddingDoesNotChangeSpeechVolume() throws {
        let result = try AudioFixture.read(AudioNormalizer.normalizedWAV(AudioFixture.wave(amplitude: 0.05, padding: 48000)))
        #expect(result.channels[0].prefix(48000).allSatisfy { $0 == 0 })
        #expect(abs(AudioFixture.rms(Array(result.channels[0].suffix(16000))) - 0.1) < 0.002)
    }

    @Test func preventsClippingWithoutCompressingTheWaveform() throws {
        let input = try AudioFixture.wave(amplitude: 0.05, spike: true)
        let source = try AudioFixture.read(input).channels[0]
        let result = try AudioFixture.read(AudioNormalizer.normalizedWAV(input)).channels[0]
        #expect(result.map { abs($0) }.max()! <= 0.892)
        let gain = result[8000] / source[8000]
        #expect(zip(source, result).allSatisfy { abs($1 - $0 * gain) < 0.0001 })
    }

    @Test(arguments: [Float(0), 0.001]) func leavesSilenceAndNearSilenceQuiet(amplitude: Float) throws {
        let input = try AudioFixture.wave(amplitude: amplitude)
        let before = try AudioFixture.read(input).channels[0]
        let after = try AudioFixture.read(AudioNormalizer.normalizedWAV(input)).channels[0]
        #expect(abs(AudioFixture.rms(before) - AudioFixture.rms(after)) < 0.0001)
    }

    @Test func capsBoostForVeryQuietSpeechAndPreservesStereoAndSampleRate() throws {
        let input = try AudioFixture.wave(amplitude: 0.008, rate: 48000, channels: 2)
        let before = try AudioFixture.read(input)
        let after = try AudioFixture.read(AudioNormalizer.normalizedWAV(input))
        #expect(after.rate == 48000)
        #expect(after.channels.count == 2)
        #expect(after.channels[0].count == before.channels[0].count)
        #expect(AudioFixture.rms(after.channels[0]) <= AudioFixture.rms(before.channels[0]) * 10.01)
        #expect(AudioFixture.rms(after.channels[0]) >= AudioFixture.rms(before.channels[0]) * 9.99)
        #expect(abs(AudioFixture.rms(after.channels[1]) / AudioFixture.rms(after.channels[0]) - 0.5) < 0.01)
    }

    @Test func rejectsUnreadableAudio() {
        #expect(throws: MiningError.self) { try AudioNormalizer.normalizedWAV(Data([1, 2, 3])) }
    }
}
