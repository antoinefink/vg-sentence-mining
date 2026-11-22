import AVFoundation
import Foundation
import Testing
@testable import MiningCore

@Test(arguments: [false, true]) func captureResamplingPreservesTheWaveformAcrossPacketSizes(interleaved: Bool) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
    let unevenSizes = Array(repeating: [480, 4921, 4097, 102, 4800], count: 20).flatMap { $0 }
    let totalFrames = unevenSizes.reduce(0, +)
    let waveform = (0..<totalFrames).map { frame in
        let time = Double(frame) / format.sampleRate
        return Float(0.2 * sin(2 * .pi * 433 * time) + 0.1 * sin(2 * .pi * 1207 * time))
    }

    func resample(_ packetSizes: [Int]) throws -> [Float] {
        let resampler = try CaptureAudioResampler(inputFormat: format)
        var start = 0
        var samples: [Float] = []
        for size in packetSizes {
            let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(size)))
            packet.frameLength = AVAudioFrameCount(size)
            let buffers = UnsafeMutableAudioBufferListPointer(packet.mutableAudioBufferList)
            for (bufferIndex, buffer) in buffers.enumerated() {
                let data = try #require(buffer.mData).assumingMemoryBound(to: Float.self)
                let channels = Int(buffer.mNumberChannels)
                for frame in 0..<size {
                    for channel in 0..<channels {
                        data[frame * channels + channel] = waveform[start + frame] * (bufferIndex + channel == 0 ? 1 : 0.5)
                    }
                }
            }
            samples.append(contentsOf: try resampler.convert(packet))
            start += size
        }
        return samples
    }

    let reference = try resample(Array(repeating: 480, count: totalFrames / 480))
    let uneven = try resample(unevenSizes)
    #expect(uneven.count == reference.count)
    let peakDifference = zip(uneven, reference).reduce(Float.zero) { max($0, abs($1.0 - $1.1)) }
    #expect(peakDifference < 0.00001)
}
