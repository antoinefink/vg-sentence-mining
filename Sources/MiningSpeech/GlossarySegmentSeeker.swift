import CoreML
import Foundation
import MiningCore
import WhisperKit

/// WhisperKit 1.1.1 removes the glossary prefix from result tokens but leaves
/// its rows in the alignment matrix. Keep both inputs on the same token origin.
final class GlossarySegmentSeeker: SegmentSeeking {
    private let base = SegmentSeeker()

    func findSeekPointAndSegments(
        decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
        currentSeek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int,
        specialToken: Int, tokenizer: WhisperTokenizer
    ) -> (Int, [TranscriptionSegment]?) {
        base.findSeekPointAndSegments(
            decodingResult: decodingResult, options: options, allSegmentsCount: allSegmentsCount,
            currentSeek: currentSeek, segmentSize: segmentSize, sampleRate: sampleRate,
            timeToken: timeToken, specialToken: specialToken, tokenizer: tokenizer
        )
    }

    func addWordTimestamps(
        segments: [TranscriptionSegment], alignmentWeights: MLMultiArray,
        tokenizer: WhisperTokenizer, seek: Int, segmentSize: Int,
        prependPunctuations: String, appendPunctuations: String,
        lastSpeechTimestamp: Float, options: DecodingOptions, timings: TranscriptionTimings
    ) throws -> [TranscriptionSegment]? {
        let prompt = options.usePrefillPrompt
            ? (options.promptTokens ?? []).suffix((Constants.maxTokenContext / 2) - 1)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            : []
        let offset = prompt.isEmpty ? 0 : prompt.count + 1 // Includes <|startofprev|>.
        let weights: MLMultiArray
        if offset == 0 {
            weights = alignmentWeights
        } else {
            guard alignmentWeights.shape.count == 2, alignmentWeights.shape[0].intValue > offset else {
                throw MiningError.message("The speech model returned invalid word alignment.")
            }
            let elementSize: Int
            switch alignmentWeights.dataType {
            case .float16: elementSize = 2
            case .float32: elementSize = 4
            case .double: elementSize = 8
            default: throw MiningError.message("The speech model returned an unsupported word alignment format.")
            }
            weights = try MLMultiArray(
                dataPointer: alignmentWeights.dataPointer.advanced(by: offset * alignmentWeights.strides[0].intValue * elementSize),
                shape: [NSNumber(value: alignmentWeights.shape[0].intValue - offset), alignmentWeights.shape[1]],
                dataType: alignmentWeights.dataType, strides: alignmentWeights.strides, deallocator: nil
            )
        }
        return try withExtendedLifetime(alignmentWeights) {
            try base.addWordTimestamps(
                segments: segments, alignmentWeights: weights, tokenizer: tokenizer,
                seek: seek, segmentSize: segmentSize, prependPunctuations: prependPunctuations,
                appendPunctuations: appendPunctuations, lastSpeechTimestamp: lastSpeechTimestamp,
                options: options, timings: timings
            )
        }
    }
}
