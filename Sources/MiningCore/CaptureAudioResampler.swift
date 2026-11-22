import AVFoundation

/// Converts successive capture packets with one sample-rate converter per input format.
public final class CaptureAudioResampler {
    private let converter: AVAudioConverter
    private var scratch: AVAudioPCMBuffer?

    public let inputFormat: AVAudioFormat

    public init(inputFormat: AVAudioFormat) throws {
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw MiningError.message("Cannot convert the game's audio format.")
        }
        self.inputFormat = inputFormat
        self.converter = converter
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard input.frameLength > 0 else { return [] }
        let outputFormat = converter.outputFormat
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)) + 32
        guard input.format == inputFormat,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity),
              let channel = output.floatChannelData?[0] else {
            throw MiningError.message("Cannot prepare the game's audio for conversion.")
        }

        var consumed: AVAudioFrameCount = 0
        var samples: [Float] = []
        var conversionError: NSError?
        var result: AVAudioConverterOutputStatus
        repeat {
            result = converter.convert(to: output, error: &conversionError) { requested, status in
                let count = min(requested, input.frameLength - consumed)
                guard count > 0, let part = self.inputFrames(input, offset: consumed, count: count) else {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed += count
                status.pointee = .haveData
                return part
            }
            if let conversionError { throw conversionError }
            guard result != .error, result != .haveData || output.frameLength > 0 else {
                throw MiningError.message("Cannot convert the game's audio samples.")
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        } while result == .haveData

        guard consumed == input.frameLength else {
            throw MiningError.message("Audio conversion did not consume the full capture packet.")
        }
        return samples
    }

    private func inputFrames(_ input: AVAudioPCMBuffer, offset: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if count == input.frameLength { return input }

        // A capture packet can span several converter requests. Preserve its unread frames.
        if (scratch?.frameCapacity ?? 0) < count {
            scratch = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: input.frameLength)
        }
        guard let scratch else { return nil }
        scratch.frameLength = count
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        for (source, destination) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = source.mData, let destinationData = destination.mData else { return nil }
            destinationData.copyMemory(from: sourceData.advanced(by: Int(offset) * bytesPerFrame),
                                       byteCount: Int(count) * bytesPerFrame)
        }
        return scratch
    }
}
