import Foundation
import MiningCore
@testable import MiningSpeech
import Testing

@Test func backgroundWindowsHaveNoSpeechToDecode() {
    let activity = SpeechActivityFilter(probabilities: Array(repeating: 0.01, count: 32), duration: 8)
    #expect(activity.sampleRange == nil)
    #expect(!activity.contains(SpokenWord(text: "Geralt", start: 2, end: 2.5)))
}

@Test func shortSpeechKeepsContextButRejectsWordsInBackgroundTail() throws {
    let activity = SpeechActivityFilter(probabilities: [0, 0, 0.9, 0, 0, 0, 0, 0], duration: 2)
    let range = try #require(activity.sampleRange)
    #expect(range.lowerBound < 8192)
    #expect(range.upperBound > 12288)
    #expect(activity.contains(SpokenWord(text: "Ja!", start: 0.5, end: 0.7)))
    #expect(!activity.contains(SpokenWord(text: "Yennefer", start: 1.5, end: 1.9)))
}

@Test func separatedVoicesKeepTheirTimingAndTheirQuietGap() {
    let activity = SpeechActivityFilter(probabilities: [0.9, 0, 0, 0, 0, 0, 0.9], duration: 1.7)
    #expect(activity.sampleRange == 0..<27200)
    #expect(activity.contains(SpokenWord(text: "Hallo", start: 0, end: 0.2)))
    #expect(activity.contains(SpokenWord(text: "Ciri", start: 1.55, end: 1.7)))
    #expect(!activity.contains(SpokenWord(text: "Geralt", start: 0.8, end: 1.0)))
}
