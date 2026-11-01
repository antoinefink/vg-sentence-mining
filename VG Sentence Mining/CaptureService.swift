import AVFoundation
import CoreImage
import MiningCore
import ScreenCaptureKit

struct AudioPacket: Sendable {
    let samples: [Float]
    let date: Date
}

enum CaptureEvent: Sendable {
    case audio(AudioPacket)
    case screenshot(Data, Date)
}

final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var continuation: AsyncThrowingStream<CaptureEvent, Error>.Continuation?
    private let queue = DispatchQueue(label: "io.antoine.vg.capture")
    private let context = CIContext()
    private var converter: AVAudioConverter?
    private var lastScreenshot = -Double.infinity
    private var lastImage: Data?
    private let hostEpoch = Date().timeIntervalSince1970 - CMClockGetTime(CMClockGetHostTimeClock()).seconds

    func start(filter: SCContentFilter) async throws -> AsyncThrowingStream<CaptureEvent, Error> {
        let events = AsyncThrowingStream<CaptureEvent, Error>(bufferingPolicy: .bufferingOldest(1600)) { continuation in
            self.continuation = continuation
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, min(1920, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))))
        configuration.height = max(1, Int(Double(configuration.width) * filter.contentRect.height / max(1, filter.contentRect.width)))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.showsCursor = false
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = capture
        lastScreenshot = -Double.infinity
        lastImage = nil
        converter = nil
        do { try await capture.startCapture() }
        catch { continuation?.finish(throwing: error); stream = nil; throw error }
        return events
    }

    func stop() async throws {
        let capture = stream
        stream = nil
        defer { continuation?.finish(); continuation = nil; lastImage = nil }
        try await capture?.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation?.finish(throwing: error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        let date = Date(timeIntervalSince1970: hostEpoch + buffer.presentationTimeStamp.seconds)
        do {
            if type == .audio {
                let samples = try audioSamples(buffer)
                if !samples.isEmpty { yield(.audio(AudioPacket(samples: samples, date: date))) }
            } else if type == .screen {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let rawStatus = attachments.first?[.status] as? Int,
                      let status = SCFrameStatus(rawValue: rawStatus) else { return }
                guard status == .complete || status == .idle else { lastImage = nil; return }
                guard buffer.presentationTimeStamp.seconds - lastScreenshot >= 0.9 else { return }
                if status == .complete {
                    guard let pixel = buffer.imageBuffer else { return }
                    let image = CIImage(cvPixelBuffer: pixel)
                    let contentRect = (attachments.first?[.contentRect] as? [String: Any])
                        .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                    let scale = (attachments.first?[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
                    guard let data = ScreenshotEncoder.jpeg(from: image, contentRect: contentRect, scaleFactor: scale, context: context) else {
                        lastImage = nil
                        return
                    }
                    lastImage = data
                }
                guard let lastImage else { return }
                lastScreenshot = buffer.presentationTimeStamp.seconds
                yield(.screenshot(lastImage, date))
            }
        } catch { continuation?.finish(throwing: error) }
    }

    private func yield(_ event: CaptureEvent) {
        if case .dropped = continuation?.yield(event) {
            continuation?.finish(throwing: MiningError.message("Transcription fell behind capture. Stop and restart the session."))
        }
    }

    private func audioSamples(_ buffer: CMSampleBuffer) throws -> [Float] {
        guard let description = buffer.formatDescription else { return [] }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        if converter?.inputFormat != format { converter = AVAudioConverter(from: format, to: target) }
        guard let converter else { throw MiningError.message("Cannot convert the game's audio format.") }
        return try buffer.withAudioBufferList { list, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.numSamples) * 16000 / format.sampleRate) + 32) else { return [] }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            if let conversionError { throw conversionError }
            guard let channel = output.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
    }
}
