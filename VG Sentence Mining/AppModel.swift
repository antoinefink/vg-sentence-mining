import AppKit
import AVFoundation
import Combine
import MiningCore
import MiningSpeech
import OSLog
import ScreenCaptureKit

@MainActor final class AppModel: ObservableObject {
    @Published var settingsPage: SettingsPage = .speech
    @Published private(set) var transcriptionModel = TranscriptionModel(rawValue: UserDefaults.standard.string(forKey: "transcriptionModel") ?? "") ?? .parakeetUltra
    @Published private(set) var speechDirectories = SpeechDirectories.load()
    var canChangeTranscriptionModel: Bool { installingModel == nil && !loadingModels && !recording && !starting && !stopping && !choosingWindow }
    @Published private(set) var installedModels: Set<TranscriptionModel> = []
    @Published private(set) var installingModel: TranscriptionModel?
    @Published private(set) var installationProgress: SpeechInstallProgress?
    @Published private(set) var installationError: String?
    private var installationTask: Task<Void, Never>?
    private var installationID = UUID()
    @Published private(set) var languagePreferences = LanguagePreferences.load()
    @Published private(set) var languageStatus: String?
    var language: GameLanguage { languagePreferences.selected }
    var enabledLanguages: [GameLanguage] { languagePreferences.languages }
    @Published var glossaryPreferences: GameGlossaryPreferences = {
        guard let data = UserDefaults.standard.data(forKey: "gameGlossaries"),
              let preferences = try? JSONDecoder().decode(GameGlossaryPreferences.self, from: data) else { return .init() }
        return preferences
    }() {
        didSet {
            activeGlossaryTerms = glossaryPreferences.selected?.terms ?? []
            if let data = try? JSONEncoder().encode(glossaryPreferences) {
                UserDefaults.standard.set(data, forKey: "gameGlossaries")
            }
        }
    }
    @Published private(set) var choosingWindow = false
    @Published private(set) var sourceName = "Game"
    @Published private(set) var rows: [Dialogue] = []
    @Published private(set) var modelsReady = false
    @Published private(set) var loadingModels = false
    @Published private(set) var recording = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    @Published var status = "Set up speech recognition to begin."
    @Published private(set) var captureRecoveryNotice: String?
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
    @Published var dictionaryForm = "" {
        didSet {
            guard selected != nil,
                  LearningTarget.resolve(selectedText: selectedWord, dictionaryForm: oldValue) != learningWord else { return }
            resetWordPronunciation()
            updateExportStatus()
            if hasReplicateToken { generatePronunciation() }
        }
    }
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
            resetWordPronunciation()
            if hasReplicateToken { generatePronunciation() }
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
    private var activeGlossaryTerms: [String] = []
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
    private var wordPlayer: AVAudioPlayer?
    private var wordAudioTarget: String?
    private var timer: AnyCancellable?
    private var audioTimeline = CaptureAudioTimeline()
    private let captureLogger = Logger(subsystem: "io.antoine.vg-sentence-mining", category: "Capture")
    private var recognitionRunning = false
    private var sentWords: [UUID: Set<String>] = [:]
    private var ankiPreferences: AnkiPreferences = {
        guard let data = UserDefaults.standard.data(forKey: "ankiExportConfigurations"), let settings = try? JSONDecoder().decode(AnkiPreferences.self, from: data) else { return AnkiPreferences() }
        return settings
    }()
    private var ankiFieldRequests: [GameLanguage: UUID] = [:]

    init() {
        refreshInstalledModels()
        if !transcriptionModel.supports(language) {
            transcriptionModel = .whisperLargeV3
            UserDefaults.standard.set(transcriptionModel.rawValue, forKey: "transcriptionModel")
        }
        if !pronunciationModel.supports(language) { pronunciationModel = .gemini31Flash }
        activeGlossaryTerms = glossaryPreferences.selected?.terms ?? []
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
    var learningWord: String? { LearningTarget.resolve(selectedText: selectedWord, dictionaryForm: dictionaryForm) }
    var hasCurrentWordAudio: Bool { wordAudio != nil && learningWord != nil && wordAudioTarget == learningWord }
    var ankiTargetForSelection: AnkiNoteConfiguration? {
        guard let selected, let catalog = ankiCatalog,
              let target = ankiPreferences.configuration(profile: catalog.profileName, language: selected.language),
              let fields = ankiFields[target.noteTypeName], catalog.decks.contains(target.deckName),
              (try? target.validate(fields: fields)) != nil else { return nil }
        return target
    }
    var canSend: Bool {
        selected.map { $0.expiresAt > now } == true && ankiTargetForSelection != nil && chosenFrame != nil && hasCurrentWordAudio && !definition.isEmpty && !sentenceTranslation.isEmpty && !translating && !sending && exportStatus == nil
    }
    var expiresIn: String {
        let seconds = max(0, Int(selected?.expiresAt.timeIntervalSince(now) ?? 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func loadModels() {
        guard canChangeTranscriptionModel else { return }
        refreshInstalledModels()
        guard installedModels.contains(transcriptionModel) else {
            modelsReady = false
            status = "Install \(transcriptionModel.name) to begin."
            loadingModels = true
            Task { await speech.unload(); loadingModels = false }
            return
        }
        let directories = speechDirectories
        loadingModels = true
        modelsReady = false
        status = "Loading \(transcriptionModel.name)…"
        Task {
            defer { loadingModels = false }
            do {
                try await speech.prepare(modelDirectory: directories.modelsDirectory, model: transcriptionModel)
                modelsReady = true
                status = "\(transcriptionModel.name) ready. Choose the game window."
            } catch { self.error = error.localizedDescription; status = "Models could not load." }
        }
    }

    func refreshInstalledModels() {
        installedModels = Set(TranscriptionModel.allCases.filter { SpeechInstallation.isInstalled($0, in: speechDirectories) })
    }

    func installModel(_ choice: TranscriptionModel) {
        guard canChangeTranscriptionModel, choice.supports(language) else { return }
        transcriptionModel = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "transcriptionModel")
        modelsReady = false
        installingModel = choice
        installationError = nil
        installationProgress = .init(message: "Preparing the download…")
        let id = UUID(), directories = speechDirectories
        installationID = id
        status = "Installing \(choice.name)…"
        installationTask = Task {
            await speech.unload()
            do {
                try await SpeechModelInstaller().install(choice, in: directories) { progress in
                    Task { @MainActor in
                        guard self.installationID == id, self.installingModel != nil else { return }
                        self.installationProgress = progress
                    }
                }
                try Task.checkCancellation()
                installingModel = nil
                installationProgress = nil
                refreshInstalledModels()
                loadModels()
            } catch {
                installingModel = nil
                installationProgress = nil
                refreshInstalledModels()
                if error is CancellationError {
                    status = "Installation cancelled. Retry when you’re ready."
                } else {
                    installationError = error.localizedDescription
                    status = "Speech installation needs attention."
                }
            }
            installationTask = nil
        }
    }

    func cancelInstallation() {
        installationTask?.cancel()
        installationProgress = .init(message: "Cancelling installation…")
    }

    func useDefaultSpeechFolder() {
        guard canChangeTranscriptionModel else { return }
        setSpeechFolder(SpeechDirectories(directory: SpeechDirectories.defaultDirectory))
    }

    func chooseSpeechFolder() {
        guard canChangeTranscriptionModel else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the speech folder"
        panel.message = "Use an existing speech folder, or choose an empty folder for new downloads."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = speechDirectories.directory
        guard panel.runModal() == .OK, let url = panel.url, canChangeTranscriptionModel else { return }
        setSpeechFolder(SpeechDirectories(directory: url))
    }

    private func setSpeechFolder(_ directories: SpeechDirectories) {
        guard directories != speechDirectories else { return }
        speechDirectories = directories
        directories.save()
        installationError = nil
        refreshInstalledModels()
        modelsReady = false
        loadingModels = true
        status = "Speech folder saved. Set up speech recognition to continue."
        Task {
            await speech.unload()
            loadingModels = false
        }
    }

    func setTranscriptionModel(_ model: TranscriptionModel) {
        guard model != transcriptionModel, canChangeTranscriptionModel, model.supports(language) else { return }
        transcriptionModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "transcriptionModel")
        loadModels()
    }

    func setLanguageEnabled(_ language: GameLanguage, enabled: Bool) {
        guard canChangeTranscriptionModel, !refreshingAnki else { return }
        let previous = self.language
        languagePreferences.setEnabled(language, enabled: enabled)
        languagePreferences.save()
        if self.language != previous { updateLanguageModels() }
        if enabled { refreshAnki() }
    }

    func setCaptureLanguage(_ language: GameLanguage) {
        guard canChangeTranscriptionModel, enabledLanguages.contains(language), language != self.language else { return }
        languagePreferences.select(language)
        languagePreferences.save()
        updateLanguageModels()
    }

    private func updateLanguageModels() {
        stopVoiceTest()
        var changes: [String] = []
        if !pronunciationModel.supports(language) {
            pronunciationModel = .gemini31Flash
            changes.append("Word pronunciation switched to \(pronunciationModel.name).")
        }
        if !transcriptionModel.supports(language) {
            let replacement: TranscriptionModel = TranscriptionModel.parakeetUltra.supports(language) ? .parakeetUltra : .whisperLargeV3
            changes.append("Transcription switched to \(replacement.name).")
            setTranscriptionModel(replacement)
        }
        languageStatus = changes.isEmpty ? nil : "For \(language.name): " + changes.joined(separator: " ")
    }

    func chooseWindow() {
        guard modelsReady, transcriptionModel.supports(language), !recording, !starting, !choosingWindow else { return }
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
            var recognitionTask: Task<Void, Never>?
            var recognitionError: Error?
            do {
                try media.reset()
                assembler = TranscriptAssembler(); rows.removeAll(); sentWords.removeAll()
                audioTimeline = CaptureAudioTimeline(); captureRecoveryNotice = nil
                await speech.start(language: language)
                let events = try await capture.start(filter: filter)
                recording = true
                recognitionRunning = true
                status = "Recording \(sourceName). Waiting for speech…"
                recognitionTask = Task {
                    do {
                        while recognitionRunning && !Task.isCancelled {
                            let words = try await speech.recognizePending(glossary: activeGlossaryTerms)
                            if let start = media.sessionStart {
                                append(words, sessionStart: start)
                                if let last = words.last {
                                    let delay = max(0, Date().timeIntervalSince(start) - last.end)
                                    status = "Recording · last dialogue arrived \(String(format: "%.1f", delay)) s after the audio"
                                }
                            }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        recognitionError = error
                        try? await capture.stop()
                    }
                }
                for try await event in events {
                    switch event {
                    case .screenshot(let data, let date): try media.addScreenshot(data, date: date)
                    case .audio(let packet):
                        let adjustment: CaptureAudioTimeline.Adjustment
                        do {
                            adjustment = try audioTimeline.align(sampleCount: packet.samples.count, at: packet.date)
                        } catch {
                            captureLogger.error("Audio timeline rejected packet: timestamp=\(packet.date.timeIntervalSince1970, privacy: .public), session_start=\(media.sessionStart?.timeIntervalSince1970 ?? 0, privacy: .public), expected_sample=\(self.audioTimeline.sampleCount, privacy: .public), packet_samples=\(packet.samples.count, privacy: .public). \(error.localizedDescription, privacy: .public)")
                            throw error
                        }
                        if adjustment.silenceSamples > 0 || adjustment.trimmedSamples > 0 {
                            captureLogger.notice("Audio timing recovered: offset_seconds=\(adjustment.offset, privacy: .public), expected_sample=\(adjustment.expectedSample, privacy: .public), timestamp=\(packet.date.timeIntervalSince1970, privacy: .public), silence_samples=\(adjustment.silenceSamples, privacy: .public), trimmed_samples=\(adjustment.trimmedSamples, privacy: .public), packet_samples=\(packet.samples.count, privacy: .public), output_rate=16000")
                        }
                        if adjustment.silenceSamples >= 4000, let start = media.sessionStart {
                            let gapStart = start.addingTimeInterval(Double(adjustment.expectedSample) / 16000)
                            captureRecoveryNotice = "Audio gap at \(gapStart.formatted(date: .omitted, time: .standard)) (\(String(format: "%.1f", Double(adjustment.silenceSamples) / 16000)) s missing). Capture continued."
                        }
                        for offset in stride(from: 0, to: adjustment.silenceSamples, by: 16000) {
                            let silence = Array(repeating: Float(0), count: min(16000, adjustment.silenceSamples - offset))
                            try media.appendAudio(silence, date: packet.date)
                            try await speech.ingest(silence)
                        }
                        let samples = Array(packet.samples.dropFirst(adjustment.trimmedSamples))
                        if !samples.isEmpty {
                            try media.appendAudio(samples, date: packet.date)
                            try await speech.ingest(samples)
                        }
                    }
                }
                recognitionRunning = false
                await recognitionTask?.value
                if let recognitionError { throw recognitionError }
                append(try await speech.finish(glossary: activeGlossaryTerms), sessionStart: media.sessionStart ?? Date())
                try media.flush()
                status = "Capture stopped. Recent dialogue expires after 30 minutes."
            } catch {
                recognitionRunning = false
                recognitionTask?.cancel()
                await recognitionTask?.value
                self.error = error.localizedDescription
                status = "Capture stopped. Reload the speech model in Settings before starting again."
                try? await capture.stop()
                try? media.flush()
                await speech.unload()
                modelsReady = false
            }
            await speech.discardSession()
            recording = false; stopping = false
        }
    }

    func discardTemporaryData() {
        installationTask?.cancel()
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
        if !pronunciationModel.supports(row.language) {
            pronunciationModel = .gemini31Flash
            languageStatus = "For \(row.language.name): Word pronunciation switched to \(pronunciationModel.name)."
        }
        now = Date()
        selected = row
        selectedWord = word.text.trimmingCharacters(in: .punctuationCharacters)
        sentence = row.text
        frames = media?.nearbyScreenshots(at: row.capturedAt) ?? []
        frameIndex = frames.indices.min(by: { abs(frames[$0].date.timeIntervalSince(row.capturedAt)) < abs(frames[$1].date.timeIntervalSince(row.capturedAt)) }) ?? 0
        updateExportStatus()
        explainSelection()
    }

    func explainSelection() {
        guard let selected, selected.expiresAt > Date() else { return }
        let id = UUID(); translationID = id
        let word = selectedWord, text = sentence, executable = codexPath
        let initialDictionary = dictionaryForm, initialDefinition = definition, initialTranslation = sentenceTranslation
        translating = true
        translationTask = Task {
            defer {
                if translationID == id {
                    translating = false
                    if hasReplicateToken, !hasCurrentWordAudio { generatePronunciation() }
                }
            }
            do {
                let result = try await translator.explain(word: word, sentence: text, language: selected.language, executable: executable)
                guard translationID == id, sentence == text, selected.expiresAt > Date() else { return }
                if dictionaryForm == initialDictionary { dictionaryForm = result.dictionaryForm }
                if definition == initialDefinition { definition = result.definition }
                if sentenceTranslation == initialTranslation { sentenceTranslation = result.sentenceTranslation }
            } catch { if translationID == id { self.error = error.localizedDescription } }
        }
    }

    private func updateExportStatus() {
        if let selected, let word = learningWord, sentWords[selected.id]?.contains(word) == true {
            exportStatus = "Already sent to Anki"
        } else { exportStatus = nil }
    }

    private func resetWordPronunciation() {
        pronunciationID = UUID(); pronunciationTask?.cancel()
        wordPlayer?.stop(); wordPlayer = nil
        wordAudio = nil; wordAudioTarget = nil
        synthesizing = false; pronunciationError = nil
    }

    func playClip() {
        guard let selected, let media else { return }
        do {
            wordPlayer?.stop()
            let url = try media.audioClip(start: max(0, selected.start - 0.2), end: selected.end + 0.3)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch { self.error = error.localizedDescription }
    }

    func saveReplicateKey(_ key: String) throws {
        try tokenStore.save(key)
        hasReplicateToken = true
        showingPronunciationSetup = false
        generatePronunciation()
    }

    func removeReplicateKey() {
        do {
            try tokenStore.delete()
            stopVoiceTest()
            hasReplicateToken = false
            resetWordPronunciation()
        } catch { self.error = error.localizedDescription }
    }

    func generatePronunciation() {
        guard let selected, selected.expiresAt > Date(), !translating, !synthesizing, let word = learningWord else { return }
        guard hasReplicateToken else { showingPronunciationSetup = true; return }
        let id = UUID(); pronunciationID = id
        let model = pronunciationModel
        synthesizing = true; pronunciationError = nil
        pronunciationTask = Task {
            defer { if pronunciationID == id { synthesizing = false } }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let token = try tokenStore.load() else {
                    hasReplicateToken = false; showingPronunciationSetup = true
                    return
                }
                let audio = try await pronunciation.generate(word: word, language: selected.language, model: model, token: token)
                guard pronunciationID == id, self.selected?.id == selected.id, learningWord == word, selected.expiresAt > Date() else { return }
                _ = try AVAudioPlayer(data: audio)
                wordAudio = audio
                wordAudioTarget = word
            } catch is CancellationError {
            } catch {
                if pronunciationID == id {
                    pronunciationError = (error as? MiningError)?.localizedDescription ?? "The word audio could not be played. Please retry."
                }
            }
        }
    }

    func playWordAudio() {
        guard hasCurrentWordAudio, let wordAudio else { return }
        do {
            player?.stop()
            wordPlayer?.stop()
            wordPlayer = try AVAudioPlayer(data: wordAudio)
            wordPlayer?.play()
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
                let word = language.sampleWord
                let audio = try await pronunciation.generate(word: word, language: language, model: model, token: token)
                try Task.checkCancellation()
                guard voiceTestID == id else { return }
                wordPlayer?.stop()
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
        guard canSend, let word = learningWord, let selected, let media, let frame = chosenFrame, let wordAudio, let target = ankiTargetForSelection else { return }
        sending = true
        let text = sentence
        let explanation = WordExplanation(dictionaryForm: dictionaryForm, definition: definition, sentenceTranslation: sentenceTranslation)
        Task {
            defer { sending = false }
            do {
                guard selected.expiresAt > Date() else { throw MiningError.message("This sentence has expired.") }
                let url = try media.audioClip(start: max(0, selected.start - 0.2), end: selected.end + 0.3)
                let audio = try Data(contentsOf: url), screenshot = try Data(contentsOf: frame.url)
                let noteID = try await AnkiClient().send(word: word, sentence: text, explanation: explanation, screenshot: screenshot, sentenceAudio: audio, wordAudio: wordAudio, configuration: target)
                sentWords[selected.id, default: []].insert(word)
                if self.selected?.id == selected.id, learningWord == word { exportStatus = "Sent to Anki · note \(noteID)" }
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
                var targets = ankiCatalog?.profileName == catalog.profileName ? ankiTargets : [:]
                var fieldsByType: [String: [String]] = [:]
                let languages = Set(enabledLanguages + rows.map(\.language))
                for language in GameLanguage.allCases where languages.contains(language) {
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
                ankiStatus = nil
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
            for (language, target) in ankiTargets where enabledLanguages.contains(language) {
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
        resetWordPronunciation()
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
