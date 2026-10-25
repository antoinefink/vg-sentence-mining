import AppKit
import AVFoundation
import Combine
import MiningCore
import MiningSpeech
import ScreenCaptureKit

@MainActor final class AppModel: ObservableObject {
    @Published var language: GameLanguage = .german
    @Published private(set) var choosingWindow = false
    @Published private(set) var sourceName = "Game"
    @Published private(set) var rows: [Dialogue] = []
    @Published private(set) var modelsReady = false
    @Published private(set) var loadingModels = false
    @Published private(set) var recording = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    @Published var status = "Load the local speech models to begin."
    @Published var error: String?
    @Published var selected: Dialogue?
    @Published var selectedWord = ""
    @Published var sentence = "" {
        didSet {
            guard sentence != oldValue, selected != nil else { return }
            translationID = UUID(); translationTask?.cancel(); translating = false
            dictionaryForm = ""; definition = ""; sentenceTranslation = ""
        }
    }
    @Published var dictionaryForm = ""
    @Published var definition = ""
    @Published var sentenceTranslation = ""
    @Published var frames: [Screenshot] = []
    @Published var frameIndex = 0
    @Published var translating = false
    @Published var sending = false
    @Published var exportStatus: String?
    @Published private(set) var wordAudio: Data?
    @Published private(set) var synthesizing = false
    @Published private(set) var hasReplicateToken = false
    @Published private(set) var pronunciationError: String?
    @Published var showingPronunciationSetup = false
    @Published private(set) var testingVoice = false
    @Published private(set) var voiceTestStatus: String?
    @Published var pronunciationModel = PronunciationModel(rawValue: UserDefaults.standard.string(forKey: "pronunciationModel") ?? "") ?? .speech28HD {
        didSet {
            guard pronunciationModel != oldValue else { return }
            UserDefaults.standard.set(pronunciationModel.rawValue, forKey: "pronunciationModel")
            stopVoiceTest(); player?.stop()
            pronunciationID = UUID(); pronunciationTask?.cancel()
            wordAudio = nil; synthesizing = false; pronunciationError = nil
            if selected != nil, hasReplicateToken { generatePronunciation() }
        }
    }
    @Published var now = Date()
    @Published private(set) var ankiCatalog: AnkiCatalog?
    @Published private(set) var ankiTargets: [GameLanguage: AnkiNoteConfiguration] = [:]
    @Published private(set) var ankiFields: [String: [String]] = [:]
    @Published private(set) var refreshingAnki = false
    @Published private(set) var loadingAnkiFields: Set<GameLanguage> = []
    @Published private(set) var ankiStatus: String?
    @Published private(set) var ankiError: String?
    @Published private(set) var settingsStatus: String?
    @Published var codexPath = UserDefaults.standard.string(forKey: "codexPath") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/codex").path
    private let speech = LocalSpeechEngine()
    private let translator = CodexTranslator()
    private let pronunciation = ReplicatePronunciation()
    private let tokenStore = ReplicateTokenStore()
    private let capture = CaptureService()
    private let windowPicker = GameWindowPicker()
    private var media: SessionMedia?
    private var assembler = TranscriptAssembler()
    private var translationTask: Task<Void, Never>?
    private var translationID = UUID()
    private var pronunciationTask: Task<Void, Never>?
    private var pronunciationID = UUID()
    private var voiceTestTask: Task<Void, Never>?
    private var voiceTestID = UUID()
    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?
    private var audioSamples = 0
    private var sentWords: [UUID: Set<String>] = [:]
    private var ankiPreferences: AnkiPreferences = {
        guard let data = UserDefaults.standard.data(forKey: "ankiExportConfigurations"), let settings = try? JSONDecoder().decode(AnkiPreferences.self, from: data) else { return AnkiPreferences() }
        return settings
    }()
    private var ankiFieldRequests: [GameLanguage: UUID] = [:]

    init() {
        do { media = try SessionMedia() } catch { self.error = error.localizedDescription }
        do { hasReplicateToken = try tokenStore.load() != nil } catch { self.error = error.localizedDescription }
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] date in self?.expire(at: date) }
        windowPicker.onSelection = { [weak self] filter in
            self?.choosingWindow = false
            self?.start(filter: filter)
        }
        windowPicker.onCancel = { [weak self] in self?.choosingWindow = false }
        windowPicker.onError = { [weak self] error in
            self?.choosingWindow = false
            self?.error = "macOS could not open the window picker. \(error.localizedDescription)"
        }
    }

    var chosenFrame: Screenshot? { frames.indices.contains(frameIndex) ? frames[frameIndex] : nil }
    var ankiTargetForSelection: AnkiNoteConfiguration? {
        guard let selected, let catalog = ankiCatalog,
              let target = ankiPreferences.configuration(profile: catalog.profileName, language: selected.language),
              let fields = ankiFields[target.noteTypeName], catalog.decks.contains(target.deckName),
              (try? target.validate(fields: fields)) != nil else { return nil }
        return target
    }
    var canSend: Bool {
        selected.map { $0.expiresAt > now } == true && ankiTargetForSelection != nil && chosenFrame != nil && wordAudio != nil && !selectedWord.isEmpty && !definition.isEmpty && !sentenceTranslation.isEmpty && !translating && !sending && exportStatus == nil
    }
    var expiresIn: String {
        let seconds = max(0, Int(selected?.expiresAt.timeIntervalSince(now) ?? 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func loadModels() {
        guard !loadingModels else { return }
        loadingModels = true
        status = "Loading local models from T9. The first download can take a few minutes."
        Task {
            defer { loadingModels = false }
            do {
                try await speech.prepare(modelDirectory: URL(fileURLWithPath: "/Volumes/T9/VG Sentence Mining/Models"))
                modelsReady = true
                status = "Local speech models ready. Choose the game window."
            } catch { self.error = error.localizedDescription; status = "Models could not load." }
        }
    }

    func chooseWindow() {
        guard modelsReady, !recording, !starting, !choosingWindow else { return }
        choosingWindow = true
        windowPicker.present()
    }

    private func start(filter: SCContentFilter) {
        guard modelsReady, !recording, !starting, let media else { return }
        if #available(macOS 15.2, *) {
            sourceName = filter.includedWindows.first?.owningApplication?.applicationName ?? "Game"
        }
        clearSelection()
        starting = true
        error = nil
        Task {
            defer { starting = false }
            do {
                try media.reset()
                assembler = TranscriptAssembler(); rows.removeAll(); sentWords.removeAll(); audioSamples = 0
                await speech.start(language: language)
                let events = try await capture.start(filter: filter)
                recording = true
                status = "Recording \(sourceName). Waiting for speech…"
                for try await event in events {
                    switch event {
                    case .screenshot(let data, let date): try media.addScreenshot(data, date: date)
                    case .audio(let packet):
                        if let start = media.sessionStart {
                            let gap = packet.date.timeIntervalSince(start) - Double(audioSamples) / 16000
                            if gap > 2 { throw MiningError.message("The audio capture was interrupted. Start a new capture to keep audio and screenshots aligned.") }
                            if gap > 0.06 {
                                let silence = Array(repeating: Float(0), count: Int(gap * 16000))
                                try media.appendAudio(silence, date: packet.date)
                                append(try await speech.append(silence), sessionStart: start)
                                audioSamples += silence.count
                            }
                        }
                        try media.appendAudio(packet.samples, date: packet.date)
                        audioSamples += packet.samples.count
                        let words = try await speech.append(packet.samples)
                        append(words, sessionStart: media.sessionStart ?? packet.date)
                        if let last = words.last {
                            let delay = max(0, Date().timeIntervalSince(media.sessionStart ?? packet.date) - last.end)
                            status = "Recording · last dialogue arrived \(String(format: "%.1f", delay)) s after the audio"
                        }
                    }
                }
                append(try await speech.finish(), sessionStart: media.sessionStart ?? Date())
                try media.flush()
                status = "Capture stopped. Recent dialogue expires after 30 minutes."
            } catch {
                self.error = error.localizedDescription
                status = "Capture stopped."
                try? await capture.stop()
                try? media.flush()
            }
            await speech.discardSession()
            recording = false; stopping = false
        }
    }

    func discardTemporaryData() {
        clearSelection()
        do { try media?.reset() } catch { self.error = error.localizedDescription }
    }

    func stop() {
        guard recording, !stopping else { return }
        stopping = true
        Task { do { try await capture.stop() } catch { self.error = error.localizedDescription } }
    }

    private func append(_ words: [SpokenWord], sessionStart: Date) {
        guard !words.isEmpty else { return }
        assembler.append(words, sessionStart: sessionStart, language: language)
        assembler.expire(now: Date())
        rows = assembler.rows
    }

    func select(_ word: SpokenWord, in row: Dialogue) {
        guard row.expiresAt > Date() else { return }
        clearSelection()
        now = Date()
        selected = row
        selectedWord = word.text.trimmingCharacters(in: .punctuationCharacters)
        sentence = row.text
        frames = media?.nearbyScreenshots(at: row.capturedAt) ?? []
        frameIndex = frames.indices.min(by: { abs(frames[$0].date.timeIntervalSince(row.capturedAt)) < abs(frames[$1].date.timeIntervalSince(row.capturedAt)) }) ?? 0
        if sentWords[row.id]?.contains(selectedWord) == true { exportStatus = "Already sent to Anki" }
        explainSelection()
        if hasReplicateToken { generatePronunciation() }
    }

    func explainSelection() {
        guard let selected, selected.expiresAt > Date() else { return }
        let id = UUID(); translationID = id
        let word = selectedWord, text = sentence, executable = codexPath
        let initialDictionary = dictionaryForm, initialDefinition = definition, initialTranslation = sentenceTranslation
        translating = true
        translationTask = Task {
            do {
                let result = try await translator.explain(word: word, sentence: text, language: selected.language, executable: executable)
                guard translationID == id, sentence == text, selected.expiresAt > Date() else { return }
                if dictionaryForm == initialDictionary { dictionaryForm = result.dictionaryForm }
                if definition == initialDefinition { definition = result.definition }
                if sentenceTranslation == initialTranslation { sentenceTranslation = result.sentenceTranslation }
            } catch { if translationID == id { self.error = error.localizedDescription } }
            if translationID == id { translating = false }
        }
    }

    func playClip() {
        guard let selected, let media else { return }
        do {
            let url = try media.audioClip(start: max(0, selected.start - 0.2), end: selected.end + 0.3)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch { self.error = error.localizedDescription }
    }

    func saveReplicateKey(_ key: String) throws {
        try tokenStore.save(key)
        hasReplicateToken = true
        showingPronunciationSetup = false
        if selected != nil { generatePronunciation() }
    }

    func removeReplicateKey() {
        do {
            try tokenStore.delete()
            stopVoiceTest()
            hasReplicateToken = false
            pronunciationID = UUID(); pronunciationTask?.cancel()
            wordAudio = nil; synthesizing = false; pronunciationError = nil
        } catch { self.error = error.localizedDescription }
    }

    func generatePronunciation() {
        guard let selected, selected.expiresAt > Date(), !synthesizing else { return }
        guard hasReplicateToken else { showingPronunciationSetup = true; return }
        let id = UUID(); pronunciationID = id
        let word = selectedWord, model = pronunciationModel
        synthesizing = true; pronunciationError = nil
        pronunciationTask = Task {
            defer { if pronunciationID == id { synthesizing = false } }
            do {
                guard let token = try tokenStore.load() else {
                    hasReplicateToken = false; showingPronunciationSetup = true
                    return
                }
                let audio = try await pronunciation.generate(word: word, language: selected.language, model: model, token: token)
                guard pronunciationID == id, self.selected?.id == selected.id, selected.expiresAt > Date() else { return }
                _ = try AVAudioPlayer(data: audio)
                wordAudio = audio
            } catch is CancellationError {
            } catch {
                if pronunciationID == id {
                    pronunciationError = (error as? MiningError)?.localizedDescription ?? "The word audio could not be played. Please retry."
                }
            }
        }
    }

    func playWordAudio() {
        guard let wordAudio else { return }
        do {
            player?.stop()
            player = try AVAudioPlayer(data: wordAudio)
            player?.play()
        } catch { pronunciationError = "The word audio could not be played. Please retry." }
    }

    func testVoice(_ language: GameLanguage) {
        guard !testingVoice else { return }
        let id = UUID(); voiceTestID = id
        let model = pronunciationModel
        testingVoice = true; voiceTestStatus = "Preparing \(language.name) pronunciation…"
        voiceTestTask = Task {
            defer { if voiceTestID == id { testingVoice = false } }
            do {
                guard let token = try tokenStore.load() else { throw MiningError.message("Save a Replicate API key first.") }
                let word = language == .german ? "Freiheit" : "libertad"
                let audio = try await pronunciation.generate(word: word, language: language, model: model, token: token)
                try Task.checkCancellation()
                guard voiceTestID == id else { return }
                player?.stop()
                player = try AVAudioPlayer(data: audio)
                player?.play()
                voiceTestStatus = "Playing “\(word)” in \(language.name)."
            } catch is CancellationError {
            } catch {
                if voiceTestID == id { voiceTestStatus = (error as? MiningError)?.localizedDescription ?? "The voice test could not finish. Please retry." }
            }
        }
    }

    func stopVoiceTest() {
        voiceTestID = UUID(); voiceTestTask?.cancel()
        testingVoice = false; voiceTestStatus = nil
    }

    func sendToAnki() {
        guard canSend, let selected, let media, let frame = chosenFrame, let wordAudio, let target = ankiTargetForSelection else { return }
        sending = true
        let word = selectedWord, text = sentence
        let explanation = WordExplanation(dictionaryForm: dictionaryForm, definition: definition, sentenceTranslation: sentenceTranslation)
        Task {
            defer { sending = false }
            do {
                guard selected.expiresAt > Date() else { throw MiningError.message("This sentence has expired.") }
                let url = try media.audioClip(start: max(0, selected.start - 0.2), end: selected.end + 0.3)
                let audio = try Data(contentsOf: url), screenshot = try Data(contentsOf: frame.url)
                let noteID = try await AnkiClient().send(word: word, sentence: text, explanation: explanation, screenshot: screenshot, sentenceAudio: audio, wordAudio: wordAudio, configuration: target)
                sentWords[selected.id, default: []].insert(word)
                if self.selected?.id == selected.id, selectedWord == word { exportStatus = "Sent to Anki · note \(noteID)" }
            } catch { self.error = error.localizedDescription }
        }
    }

    func refreshAnki() {
        guard !refreshingAnki else { return }
        refreshingAnki = true; ankiError = nil; settingsStatus = nil
        Task {
            defer { refreshingAnki = false }
            do {
                let client = AnkiClient()
                let catalog = try await client.catalog()
                var targets: [GameLanguage: AnkiNoteConfiguration] = [:], fieldsByType: [String: [String]] = [:]
                for language in GameLanguage.allCases {
                    let stored = ankiPreferences.configuration(profile: catalog.profileName, language: language)
                    let draft = ankiCatalog?.profileName == catalog.profileName ? ankiTargets[language] : nil
                    var target = draft ?? stored ?? .suggested(profile: catalog.profileName, language: language, decks: catalog.decks, noteTypes: catalog.noteTypes)
                    if !target.noteTypeName.isEmpty, catalog.noteTypes.contains(target.noteTypeName) {
                        let fields: [String]
                        if let cached = fieldsByType[target.noteTypeName] { fields = cached }
                        else { fields = try await client.fields(noteType: target.noteTypeName); fieldsByType[target.noteTypeName] = fields }
                        if target.mapping.isEmpty { target.mapping = AnkiNoteConfiguration.suggestedMapping(fields: fields) }
                    }
                    targets[language] = target
                }
                guard try await client.activeProfile() == catalog.profileName else { throw MiningError.message("Anki changed profiles. Refresh to reconnect.") }
                ankiFieldRequests.removeAll(); loadingAnkiFields.removeAll()
                ankiCatalog = catalog; ankiTargets = targets; ankiFields = fieldsByType
                ankiStatus = "Connected to Anki. Save your export choices for this profile."
            } catch {
                ankiCatalog = nil; ankiTargets.removeAll(); ankiFields.removeAll()
                ankiError = error.localizedDescription
            }
        }
    }

    func updateAnkiConfiguration(_ configuration: AnkiNoteConfiguration, for language: GameLanguage) {
        let previousType = ankiTargets[language]?.noteTypeName
        var updated = configuration
        settingsStatus = nil; ankiError = nil
        if previousType == updated.noteTypeName { ankiTargets[language] = updated; return }
        updated.mapping = [:]; ankiTargets[language] = updated
        let id = UUID(); ankiFieldRequests[language] = id
        guard !updated.noteTypeName.isEmpty else { loadingAnkiFields.remove(language); return }
        loadingAnkiFields.insert(language)
        Task {
            defer { if ankiFieldRequests[language] == id { loadingAnkiFields.remove(language) } }
            do {
                let client = AnkiClient()
                let fields = try await client.fields(noteType: updated.noteTypeName)
                guard try await client.activeProfile() == updated.profileName else { throw MiningError.message("Anki changed profiles. Refresh to reconnect.") }
                guard ankiFieldRequests[language] == id, ankiCatalog?.profileName == updated.profileName, ankiTargets[language]?.noteTypeName == updated.noteTypeName else { return }
                var target = ankiTargets[language]!
                target.mapping = AnkiNoteConfiguration.suggestedMapping(fields: fields)
                ankiFields[target.noteTypeName] = fields; ankiTargets[language] = target
            } catch { if ankiFieldRequests[language] == id { ankiError = error.localizedDescription } }
        }
    }

    func suggestAnkiMapping(for language: GameLanguage) {
        guard var target = ankiTargets[language], let fields = ankiFields[target.noteTypeName] else { return }
        target.mapping = AnkiNoteConfiguration.suggestedMapping(fields: fields)
        ankiTargets[language] = target; settingsStatus = nil
    }

    func saveSettings() {
        UserDefaults.standard.set(codexPath, forKey: "codexPath")
        do {
            guard !refreshingAnki, loadingAnkiFields.isEmpty else { throw MiningError.message("Wait for Anki discovery to finish before saving.") }
            var preferences = ankiPreferences
            for (language, target) in ankiTargets {
                try target.validate(fields: ankiFields[target.noteTypeName] ?? [])
                preferences.set(target, for: language)
            }
            let data = try JSONEncoder().encode(preferences)
            UserDefaults.standard.set(data, forKey: "ankiExportConfigurations")
            ankiPreferences = preferences
            objectWillChange.send()
            settingsStatus = "Settings saved."
            ankiError = nil
        } catch { ankiError = error.localizedDescription; settingsStatus = nil }
    }

    func dismissSelection() { clearSelection() }

    private func clearSelection() {
        translationID = UUID(); translationTask?.cancel(); translating = false
        pronunciationID = UUID(); pronunciationTask?.cancel(); synthesizing = false
        wordAudio = nil; pronunciationError = nil
        player?.stop(); player = nil
        selected = nil; selectedWord = ""; sentence = ""; dictionaryForm = ""; definition = ""; sentenceTranslation = ""; frames = []; exportStatus = nil
        do { try media?.clearPreview() } catch { self.error = error.localizedDescription }
    }

    private func expire(at date: Date) {
        if selected != nil { now = date }
        let previousCount = assembler.rows.count
        assembler.expire(now: date)
        if assembler.rows.count != previousCount {
            rows = assembler.rows
        }
        if !sentWords.isEmpty {
            let activeIDs = Set(rows.map(\.id))
            sentWords = sentWords.filter { activeIDs.contains($0.key) }
        }
        if let selected, selected.expiresAt <= date { clearSelection(); status = "The selected sentence expired from the 30-minute buffer." }
        do { try media?.expire(now: date) } catch { self.error = error.localizedDescription }
    }
}
