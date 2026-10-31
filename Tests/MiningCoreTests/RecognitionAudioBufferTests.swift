import Testing
@testable import MiningCore

@Test func recognitionAudioBufferUsesFourSecondStartAndTwoSecondCadence() throws {
    var buffer = RecognitionAudioBuffer(sampleRate: 10)
    try buffer.append(Array(repeating: 0, count: 39))
    #expect(buffer.next() == nil)
    try buffer.append([0])
    let first = try #require(buffer.next())
    #expect(first.startSample == 0 && first.endSample == 40)
    #expect(!first.isFinal)
    #expect(buffer.next()?.endSample == 40)
    buffer.acknowledge(first)
    try buffer.append(Array(repeating: 0, count: 19))
    #expect(buffer.next() == nil)
    try buffer.append([0])
    let second = try #require(buffer.next())
    #expect(second.startSample == 0 && second.endSample == 60)
    buffer.acknowledge(second)
    #expect(buffer.next() == nil)
}

@Test func recognitionAudioBufferKeepsContiguousAudioArrivingDuringInference() throws {
    var buffer = RecognitionAudioBuffer(sampleRate: 10)
    try buffer.append((0..<40).map(Float.init))
    let inFlight = try #require(buffer.next())
    try buffer.append((40..<220).map(Float.init))
    buffer.acknowledge(inFlight)
    var windows: [RecognitionAudioBuffer.Window] = []
    while let window = buffer.next() {
        windows.append(window)
        buffer.acknowledge(window)
    }
    #expect(windows.map(\.endSample) == [80, 120, 160, 200, 220])
    #expect(windows.map(\.startSample) == [0, 40, 80, 120, 140])
    for window in windows {
        #expect(window.samples == (window.startSample..<window.endSample).map(Float.init))
    }
    #expect(inFlight.samples == (0..<40).map(Float.init))
    #expect(buffer.totalSamples == 220)
}

@Test func recognitionAudioBufferRejectsOverflowWithoutDroppingAudio() throws {
    var buffer = RecognitionAudioBuffer(sampleRate: 10)
    try buffer.append((0..<320).map(Float.init))
    #expect(throws: MiningError.self) { try buffer.append([320]) }
    #expect(buffer.totalSamples == 320)
    let first = try #require(buffer.next())
    #expect(first.samples == (0..<40).map(Float.init))
    buffer.acknowledge(first)
    let second = try #require(buffer.next())
    buffer.acknowledge(second)
    let third = try #require(buffer.next())
    buffer.acknowledge(third)
    try buffer.append((320..<360).map(Float.init))
    #expect(buffer.totalSamples == 360)
}

@Test func recognitionAudioBufferFinalDrainsBacklogAndShortTail() throws {
    var buffer = RecognitionAudioBuffer(sampleRate: 10)
    try buffer.append((0..<185).map(Float.init))
    var windows: [RecognitionAudioBuffer.Window] = []
    while let window = buffer.next(final: true) {
        windows.append(window)
        buffer.acknowledge(window)
        #expect(windows.count <= 5)
        if windows.count > 5 { break }
    }
    #expect(windows.map(\.endSample) == [40, 80, 120, 160, 185])
    #expect(windows.allSatisfy { $0.isFinal })
    #expect(windows.last?.samples == (105..<185).map(Float.init))
    #expect(buffer.next(final: true) == nil)
}

@Test func recognitionAudioBufferReplaysFinalTailOnceAfterNormalAcknowledgement() throws {
    var buffer = RecognitionAudioBuffer(sampleRate: 10)
    try buffer.append((0..<120).map(Float.init))
    buffer.acknowledge(try #require(buffer.next()))
    buffer.acknowledge(try #require(buffer.next()))
    let normal = try #require(buffer.next())
    buffer.acknowledge(normal)
    let final = try #require(buffer.next(final: true))
    #expect(final.samples == normal.samples)
    #expect(final.isFinal)
    buffer.acknowledge(final)
    #expect(buffer.next(final: true) == nil)
    #expect(final.startSample == 40 && final.endSample == 120)
    #expect(buffer.totalSamples == 120)

    try buffer.append([120])
    #expect(buffer.next() == nil)
    let tail = try #require(buffer.next(final: true))
    #expect(tail.samples == (41..<121).map(Float.init))
    buffer.acknowledge(tail)
    #expect(buffer.next(final: true) == nil)

    buffer.reset()
    #expect(buffer.totalSamples == 0)
    #expect(buffer.next(final: true) == nil)
    try buffer.append([0, 1, 2])
    let short = try #require(buffer.next(final: true))
    #expect(short.startSample == 0 && short.endSample == 3)
    buffer.acknowledge(short)
    #expect(buffer.next(final: true) == nil)
}
