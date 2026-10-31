import Foundation

/// Keeps overlapping recognition windows contiguous while inference is behind capture.
public struct RecognitionAudioBuffer: Sendable {
    public struct Window: Sendable {
        public let samples: [Float]
        public let startSample: Int
        public let endSample: Int
        public let isFinal: Bool
    }

    private let sampleRate: Int
    private var samples: [Float] = []
    private var retainedStart: Int { totalSamples - samples.count }
    private var acknowledgedEnd = 0
    private var finalAcknowledgedEnd = 0
    public private(set) var totalSamples = 0

    public init(sampleRate: Int = 16_000) {
        precondition(sampleRate > 0 && sampleRate <= Int.max / 32)
        self.sampleRate = sampleRate
    }

    /// Fails before changing the buffer if inference cannot keep up within the retention bound.
    public mutating func append(_ audio: [Float]) throws {
        guard audio.count <= sampleRate * 32 - samples.count else {
            throw MiningError.message("Speech recognition fell behind: the 32-second audio buffer is full.")
        }
        samples.append(contentsOf: audio)
        totalSamples += audio.count
    }

    /// Does not advance the recognition cursor until the returned window is acknowledged.
    public func next(final: Bool = false) -> Window? {
        guard totalSamples > 0 else { return nil }
        if final {
            guard finalAcknowledgedEnd < totalSamples else { return nil }
        } else {
            let minimumNew = sampleRate * (acknowledgedEnd == 0 ? 4 : 2)
            guard totalSamples - acknowledgedEnd >= minimumNew else { return nil }
        }
        let end = min(totalSamples, acknowledgedEnd + sampleRate * 4)
        let start = max(0, end - sampleRate * 8)
        return Window(
            samples: Array(samples[(start - retainedStart)..<(end - retainedStart)]),
            startSample: start,
            endSample: end,
            isFinal: final
        )
    }

    public mutating func acknowledge(_ window: Window) {
        guard window.endSample >= acknowledgedEnd, window.endSample <= totalSamples,
              window.startSample >= retainedStart else { return }
        acknowledgedEnd = window.endSample
        if window.isFinal { finalAcknowledgedEnd = window.endSample }
        let newStart = max(0, acknowledgedEnd - sampleRate * 8)
        samples.removeFirst(newStart - retainedStart)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        acknowledgedEnd = 0
        finalAcknowledgedEnd = 0
        totalSamples = 0
    }
}
