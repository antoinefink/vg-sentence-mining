import Foundation
import Testing
@testable import MiningCore

@Test func joinsWindowSeamsButSeparatesSpeakersAndSentences() {
    var assembler = TranscriptAssembler()
    let date = Date(timeIntervalSince1970: 1000)
    let first = SpokenWord(text: "Ich", start: 0, end: 0.3, speaker: 0)
    let second = SpokenWord(text: "warte.", start: 0.4, end: 1, speaker: 0)
    assembler.append([first], sessionStart: date, language: .german)
    assembler.append([first, second, .init(text: "Warum?", start: 1.2, end: 2, speaker: 1)], sessionStart: date, language: .german)
    #expect(assembler.rows.map(\.text) == ["Ich warte.", "Warum?"])
    #expect(assembler.rows[0].words.count == 2)
}

@Test func expiresAtThirtyMinutesIncludingSelectedDraftSource() {
    var assembler = TranscriptAssembler()
    let date = Date(timeIntervalSince1970: 1000)
    assembler.append([.init(text: "Hola.", start: 0, end: 1)], sessionStart: date, language: .spanish)
    assembler.expire(now: date.addingTimeInterval(1799))
    #expect(assembler.rows.count == 1)
    assembler.expire(now: date.addingTimeInterval(1800))
    #expect(assembler.rows.isEmpty)
}

@Test func overlappingWindowsDoNotRepeatWordsButKeepRealRepetitions() {
    var assembler = TranscriptAssembler()
    let date = Date()
    assembler.append([.init(text: "gestern", start: 3.04, end: 3.36, speaker: 0)], sessionStart: date, language: .german)
    assembler.append([.init(text: "gestern", start: 3.2, end: 3.6, speaker: 0), .init(text: "gesperrt.", start: 3.6, end: 4.4, speaker: 0)], sessionStart: date, language: .german)
    assembler.append([.init(text: "Nein", start: 5, end: 5.3, speaker: 0), .init(text: "nein!", start: 5.4, end: 5.8, speaker: 0)], sessionStart: date, language: .german)
    #expect(assembler.rows.map(\.text) == ["gestern gesperrt.", "Nein nein!"])
}

@Test func escapesGameAndModelTextBeforeSendingToAnki() {
    #expect(CardHTML.escape("<script>\"&'</script>") == "&lt;script&gt;&quot;&amp;&#39;&lt;/script&gt;")
}

@Test func overlappingWordTimingsKeepShortWords() {
    var assembler = TranscriptAssembler()
    let date = Date()
    assembler.append([
        .init(text: "sein.", start: 48.8, end: 49.44),
        .init(text: "Es", start: 49.2, end: 49.44),
        .init(text: "sei", start: 49.68, end: 49.92),
        .init(text: "denn,", start: 49.92, end: 50.4),
    ], sessionStart: date, language: .german)
    #expect(assembler.rows.map(\.text) == ["sein.", "Es sei denn,"])
    let overlap = Dialogue(words: [.init(text: "zu", start: 1, end: 2), .init(text: "sein", start: 1.3, end: 1.8)], capturedAt: date, language: .german)
    #expect(overlap.end == 2)
}

@Test func speakerLabelChangesKeepTheWitcherDialogueInWholeSentences() {
    var assembler = TranscriptAssembler()
    let date = Date(timeIntervalSince1970: 1000)
    assembler.append([.init(text: "Schade,", start: 0, end: 0.5, speaker: 1)], sessionStart: date, language: .german)
    let continuation = ["wir", "hätten", "was", "tun", "können,", "aber", "nicht", "umsonst."].enumerated().map { index, text in
        SpokenWord(text: text, start: 0.6 + Double(index) * 0.3, end: 0.9 + Double(index) * 0.3, speaker: 0)
    }
    assembler.append(continuation, sessionStart: date, language: .german)
    assembler.append([.init(text: "Danke", start: 5, end: 5.3)], sessionStart: date, language: .german)
    assembler.append([
        .init(text: "für", start: 5.4, end: 5.6, speaker: 0),
        .init(text: "alles.", start: 5.7, end: 6, speaker: 0),
    ], sessionStart: date, language: .german)
    #expect(assembler.rows.map(\.text) == ["Schade, wir hätten was tun können, aber nicht umsonst.", "Danke für alles."])
    #expect(assembler.rows.map(\.speaker) == [0, 0])
    #expect(assembler.rows.first?.words.count == 9)
    #expect(assembler.rows.first?.capturedAt == date)
}

@Test func briefPausesStayInsideSpanishSentencesButLongPausesSeparateTurns() {
    var assembler = TranscriptAssembler()
    assembler.append([
        .init(text: "Gracias", start: 0, end: 0.4),
        .init(text: "por", start: 1.5, end: 1.7, speaker: 1),
        .init(text: "todo", start: 1.8, end: 2.2, speaker: 1),
        .init(text: "Adiós.", start: 4.2, end: 4.7, speaker: 0),
    ], sessionStart: Date(), language: .spanish)
    #expect(assembler.rows.map(\.text) == ["Gracias por todo", "Adiós."])
    #expect(assembler.rows.map(\.speaker) == [1, 0])
}

@Test func closingQuotesDoNotHideSentenceBoundaries() {
    var assembler = TranscriptAssembler()
    assembler.append([
        .init(text: "„Warte!“", start: 0, end: 0.5, speaker: 0),
        .init(text: "Warum?", start: 0.6, end: 1, speaker: 0),
    ], sessionStart: Date(), language: .german)
    #expect(assembler.rows.map(\.text) == ["„Warte!“", "Warum?"])
}

@Test func sentenceSpeakerIgnoresUnknownWordsAndKeepsTiesStable() {
    let date = Date()
    let words: [SpokenWord] = [
        .init(text: "a", start: 0, end: 0.1),
        .init(text: "b", start: 0.1, end: 0.2, speaker: 1),
        .init(text: "c", start: 0.2, end: 0.3, speaker: 0),
        .init(text: "d", start: 0.3, end: 0.4, speaker: 0),
    ]
    #expect(Dialogue(words: words, capturedAt: date, language: .german).speaker == 0)
    #expect(Dialogue(words: Array(words.prefix(3)), capturedAt: date, language: .german).speaker == 1)
    #expect(Dialogue(words: [words[0]], capturedAt: date, language: .german).speaker == nil)
}
