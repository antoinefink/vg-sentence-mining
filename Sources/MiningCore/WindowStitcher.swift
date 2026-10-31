import Foundation

/// Aligns overlapping recognition windows using their shared words and approximate timing.
public struct WindowStitcher: Sendable {
    private var history: [SpokenWord] = []
    private var emittedThrough: TimeInterval = -1

    public init() {}

    public mutating func append(_ candidates: [SpokenWord], through cutoff: TimeInterval) -> [SpokenWord] {
        history.removeAll { $0.end < cutoff - 12 }
        guard !candidates.isEmpty else { return [] }
        let previous = history.suffix(10)
        var anchor: Int?

        if !previous.isEmpty {
            for length in stride(from: min(previous.count, candidates.count), through: 1, by: -1) {
                let suffix = previous.suffix(length)
                var bestError = Double.infinity
                for end in (length - 1)..<candidates.count {
                    let window = candidates[(end - length + 1)...end]
                    var error: Double = 0
                    let matches = zip(suffix, window).allSatisfy { old, new in
                        let startDifference = abs(old.start - new.start)
                        let endDifference = abs(old.end - new.end)
                        error += startDifference + endDifference
                        return Self.normalized(old.text) == Self.normalized(new.text)
                            && startDifference <= 0.9 && endDifference <= 0.9
                            && (length > 1 || (old.start < new.end && new.start < old.end))
                    }
                    if matches, error < bestError {
                        bestError = error
                        anchor = end
                    }
                }
                if anchor != nil { break }
            }
        }

        let remaining = candidates.dropFirst(anchor.map { $0 + 1 } ?? 0)
        let fresh = remaining.filter { $0.end <= cutoff && (anchor != nil || $0.end > emittedThrough + 0.03) }
        history.append(contentsOf: fresh)
        if let last = fresh.last { emittedThrough = max(emittedThrough, last.end) }
        return fresh
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }
}
