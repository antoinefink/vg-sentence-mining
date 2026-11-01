import Foundation

/// Aligns 16 kHz PCM with packet timestamps without moving the session origin.
public struct CaptureAudioTimeline: Sendable {
    public struct Adjustment: Sendable {
        public let silenceSamples: Int
        public let trimmedSamples: Int
        public let offset: TimeInterval
        public let expectedSample: Int
    }

    private let sampleRate = 16_000
    private var sessionStart: Date?
    public private(set) var sampleCount = 0

    public init() {}

    public mutating func align(sampleCount packetSamples: Int, at date: Date) throws -> Adjustment {
        guard packetSamples >= 0, date.timeIntervalSince1970.isFinite else {
            throw MiningError.message("The audio capture returned an invalid timestamp.")
        }
        let origin = sessionStart ?? date
        let offset = date.timeIntervalSince(origin) - Double(sampleCount) / Double(sampleRate)
        guard offset.isFinite, abs(offset) <= 10 else {
            throw MiningError.message("The audio capture clock jumped \(String(format: "%.3f", offset)) seconds. Start a new capture to restore alignment.")
        }
        let silence = offset > 0.06 ? Int((offset * Double(sampleRate)).rounded()) : 0
        let trim = offset < -0.06 ? min(packetSamples, Int((-offset * Double(sampleRate)).rounded())) : 0
        let adjustment = Adjustment(silenceSamples: silence, trimmedSamples: trim, offset: offset, expectedSample: sampleCount)
        if packetSamples > 0 {
            sessionStart = origin
            sampleCount += silence + packetSamples - trim
        }
        return adjustment
    }
}
