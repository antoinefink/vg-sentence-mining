import Foundation
import Testing
@testable import MiningCore

@Test func captureRecoversTheReportedGapBeyondTwoSeconds() throws {
    var timeline = CaptureAudioTimeline()
    let start = Date(timeIntervalSince1970: 1000)
    _ = try timeline.align(sampleCount: 16000, at: start)
    let recovered = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(3.25))
    #expect(recovered.silenceSamples == 36000)
    #expect(recovered.trimmedSamples == 0)
    #expect(recovered.expectedSample == 16000)
    #expect(timeline.sampleCount == 68000)
    let following = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(4.25))
    #expect(following.silenceSamples == 0 && following.trimmedSamples == 0)
    #expect(timeline.sampleCount == 84000)
}

@Test func consecutiveAudioGapsAndOverlapsPreserveOneTimeline() throws {
    var timeline = CaptureAudioTimeline()
    let start = Date(timeIntervalSince1970: 1000)
    _ = try timeline.align(sampleCount: 16000, at: start)
    _ = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(3.25))
    let secondGap = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(6))
    #expect(secondGap.silenceSamples == 28000)
    let overlap = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(6.5))
    #expect(overlap.trimmedSamples == 8000 && overlap.silenceSamples == 0)
    let duplicate = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(6))
    #expect(duplicate.trimmedSamples == 16000)
    #expect(timeline.sampleCount == 120000)
    let following = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(7.5))
    #expect(following.offset == 0)
    #expect(timeline.sampleCount == 136000)
}

@Test func captureRecoveryIsBoundedAndRejectedPacketsCannotMoveTheTimeline() throws {
    var timeline = CaptureAudioTimeline()
    let start = Date(timeIntervalSince1970: 1000)
    _ = try timeline.align(sampleCount: 16000, at: start)
    #expect(throws: MiningError.self) {
        try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(11.001))
    }
    #expect(timeline.sampleCount == 16000)
    #expect(throws: MiningError.self) {
        try timeline.align(sampleCount: 16000, at: Date(timeIntervalSince1970: .nan))
    }
    #expect(timeline.sampleCount == 16000)
    let boundary = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(11))
    #expect(boundary.silenceSamples == 160000)
    #expect(timeline.sampleCount == 192000)
    #expect(throws: MiningError.self) {
        try timeline.align(sampleCount: 16000, at: start)
    }
    #expect(timeline.sampleCount == 192000)
}

@Test func subThresholdJitterAndEmptyPacketsDoNotCreateMissingAudio() throws {
    var timeline = CaptureAudioTimeline()
    let start = Date(timeIntervalSince1970: 1000)
    _ = try timeline.align(sampleCount: 0, at: start)
    _ = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(20))
    let jitter = try timeline.align(sampleCount: 16000, at: start.addingTimeInterval(21.025))
    #expect(jitter.silenceSamples == 0 && jitter.trimmedSamples == 0)
    #expect(timeline.sampleCount == 32000)
}

@Test func aLongCaptureRecoversOneGapWithoutAccumulatingTimingError() throws {
    var timeline = CaptureAudioTimeline()
    let start = Date(timeIntervalSince1970: 1000)
    var padding = 0
    var trimmed = 0
    for packet in 0..<240000 {
        let gap = packet >= 235300 ? 2.25 : 0
        let adjustment = try timeline.align(sampleCount: 160, at: start.addingTimeInterval(Double(packet) / 100 + gap))
        padding += adjustment.silenceSamples
        trimmed += adjustment.trimmedSamples
    }
    #expect(padding == 36000)
    #expect(trimmed == 0)
    #expect(timeline.sampleCount == 38436000)
}
