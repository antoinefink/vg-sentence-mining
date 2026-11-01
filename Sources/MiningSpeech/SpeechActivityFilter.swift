import Foundation
import FluidAudio
import MiningCore

struct SpeechActivityFilter {
    static let threshold: Float = 0.35
    private static let chunkDuration = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
    private let regions: [Range<Double>]
    private let duration: Double

    init(probabilities: [Float], duration: Double) {
        self.duration = duration
        var regions: [Range<Double>] = []
        for (index, probability) in probabilities.enumerated() where probability >= Self.threshold {
            let start = max(0, Double(index) * Self.chunkDuration - 0.25)
            let end = min(duration, Double(index + 1) * Self.chunkDuration + 0.25)
            guard end > start else { continue }
            if let last = regions.last, start <= last.upperBound {
                regions[regions.count - 1] = last.lowerBound..<end
            } else {
                regions.append(start..<end)
            }
        }
        self.regions = regions
    }

    var sampleRange: Range<Int>? {
        guard let first = regions.first, let last = regions.last else { return nil }
        return Int((first.lowerBound * 16000).rounded(.down))..<min(Int((duration * 16000).rounded()), Int((last.upperBound * 16000).rounded(.up)))
    }

    func contains(_ word: SpokenWord) -> Bool {
        regions.contains { word.start < $0.upperBound && word.end > $0.lowerBound }
    }
}
