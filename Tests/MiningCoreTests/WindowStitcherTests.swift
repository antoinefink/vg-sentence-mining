import Testing
@testable import MiningCore

@Test func repeatedSingleWordWithoutTemporalOverlapDoesNotAnchor() {
    var stitcher = WindowStitcher()
    _ = stitcher.append([.init(text: "Ja.", start: 3, end: 3.3)], through: 3.3)
    let next: [SpokenWord] = [
        .init(text: "Nein.", start: 3.4, end: 3.6),
        .init(text: "Ja.", start: 3.7, end: 4),
        .init(text: "Weiter.", start: 4.2, end: 4.5),
    ]
    #expect(stitcher.append(next, through: 4.5).map(\.text) == ["Nein.", "Ja.", "Weiter."])
}

@Test func shiftedWindowDoesNotDuplicateNegation() {
    var stitcher = WindowStitcher()
    let first: [SpokenWord] = [
        .init(text: "Aber", start: 17.92, end: 18.24),
        .init(text: "Freiheit", start: 18.24, end: 19.04),
        .init(text: "ist", start: 19.04, end: 19.28),
        .init(text: "nicht", start: 19.28, end: 19.36),
    ]
    let second: [SpokenWord] = [
        first[0], first[1],
        .init(text: "ist", start: 19.12, end: 19.44),
        .init(text: "nicht", start: 19.44, end: 19.76),
        .init(text: "umsonst.", start: 19.76, end: 20.64),
    ]
    let words = stitcher.append(first, through: 19.5) + stitcher.append(second, through: 21.5)
    #expect(words.map(\.text).joined(separator: " ") == "Aber Freiheit ist nicht umsonst.")
    var third = second
    third[4].end = 20.88
    #expect(stitcher.append(third, through: 23.5).isEmpty)
}

@Test func preservesGenuineRepeatedWordsAndPhrases() {
    var stitcher = WindowStitcher()
    let first = SpokenWord(text: "Nein", start: 1, end: 1.2)
    #expect(stitcher.append([first], through: 1.3).count == 1)
    let repeated = SpokenWord(text: "nein!", start: 1.35, end: 1.55)
    #expect(stitcher.append([first, repeated], through: 2).map(\.text) == ["nein!"])

    var phrases = WindowStitcher()
    let firstPhrase = [SpokenWord(text: "Komm", start: 1, end: 1.2), SpokenWord(text: "mit", start: 1.2, end: 1.4)]
    _ = phrases.append(firstPhrase, through: 1.5)
    let nextPhrase = [SpokenWord(text: "komm", start: 1.6, end: 1.8), SpokenWord(text: "mit!", start: 1.8, end: 2)]
    #expect(phrases.append(firstPhrase + nextPhrase, through: 2.5).map(\.text) == ["komm", "mit!"])
}

@Test func anchoredWindowKeepsNewWordSharingPreviousEnd() {
    var stitcher = WindowStitcher()
    let previous = SpokenWord(text: "sein.", start: 48.8, end: 49.44)
    _ = stitcher.append([previous], through: 49.5)
    let next = [previous, SpokenWord(text: "Es", start: 49.2, end: 49.44), SpokenWord(text: "sei", start: 49.68, end: 49.92)]
    #expect(stitcher.append(next, through: 50).map(\.text) == ["Es", "sei"])
    #expect(stitcher.append(next, through: 52).isEmpty)
}
