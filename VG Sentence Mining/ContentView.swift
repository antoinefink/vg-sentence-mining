import AppKit
import MiningCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingCaptureSetup = false
    @State private var followingLive = true

    var body: some View {
        HSplitView {
            transcriptPane
                .frame(minWidth: 460, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
            if model.selected != nil {
                WordInspector(model: model)
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 540, maxHeight: .infinity, alignment: .top)
                    .background(.background.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingCaptureSetup) { CaptureSetupView(model: model) }
        .sheet(isPresented: $model.showingPronunciationSetup) { PronunciationKeyView(model: model) }
        .task {
            if !model.modelsReady && !model.loadingModels { model.loadModels() }
            model.refreshAnki()
        }
        .alert("VG Sentence Mining", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.recording {
                    Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(model.sourceName).font(.callout)
                } else {
                    Text(model.rows.isEmpty ? "Dialogue" : "Recent dialogue").font(.headline)
                }
                if model.recording || !model.rows.isEmpty {
                    Text((model.rows.first?.language ?? model.language).name).font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Language", selection: Binding(get: { model.language }, set: model.setCaptureLanguage)) {
                        ForEach(model.enabledLanguages, id: \.self) { Text($0.name).tag($0) }
                    }.labelsHidden().fixedSize().disabled(!model.canChangeTranscriptionModel)
                }
                GameGlossaryPicker(model: model)
                Spacer()
                if model.recording {
                    Button("Stop", action: model.stop).disabled(model.stopping)
                } else if !model.rows.isEmpty {
                    Button("New capture…") { showingCaptureSetup = true }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
            Divider()
            Group {
                if model.rows.isEmpty { welcome }
                else { transcript }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.rows.isEmpty || model.captureRecoveryNotice != nil {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.status).lineLimit(1)
                        if let notice = model.captureRecoveryNotice {
                            Text(notice).foregroundStyle(.primary)
                        }
                    }
                    Spacer()
                }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9).background(.bar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label(model.recording ? "Listening for dialogue" : "Mine words as you play", systemImage: "text.bubble")
        } description: {
            Text(model.recording
                 ? "Play your game, then return here to choose a word."
                 : "Turn game dialogue into Anki cards.")
        } actions: {
            VStack(spacing: 12) {
                if !model.recording {
                    Button(model.choosingWindow ? "Choose the game in macOS…" : model.installingModel != nil ? "View installation…" : model.modelsReady ? "Start capture…" : "Set up speech recognition…") { showingCaptureSetup = true }
                        .buttonStyle(.borderedProminent).controlSize(.regular).disabled(model.choosingWindow || model.starting)
                }
                if model.loadingModels {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing speech recognition…").font(.callout).foregroundStyle(.secondary) }
                } else if let progress = model.installationProgress {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress.message).font(.callout).foregroundStyle(.secondary) }
                } else if !model.modelsReady && !model.recording {
                    Text("One model download. Then capture dialogue locally.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            VStack(spacing: 0) {
                HStack {
                    Text("Last 30 minutes").foregroundStyle(.secondary)
                    Spacer()
                    if !followingLive {
                        Button("Jump to latest", systemImage: "arrow.down") {
                            followingLive = true
                            if let id = model.rows.last?.id { scroll.scrollTo(id, anchor: .bottom) }
                        }.buttonStyle(.borderless)
                    }
                }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
                List {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Text(row.capturedAt, format: .dateTime.hour().minute().second())
                                Text(row.speaker.map { "Speaker \($0 + 1)" } ?? "Speaker unknown")
                            }.font(.caption).foregroundStyle(.secondary)
                            WordFlowLayout(spacing: 3) {
                                ForEach(Array(row.words.enumerated()), id: \.offset) { _, word in
                                    Button {
                                        followingLive = false
                                        model.select(word, in: row)
                                    } label: {
                                        Text(word.text).font(.body).padding(.horizontal, 2).padding(.vertical, 2)
                                    }
                                    .buttonStyle(.plain)
                                    .background(model.selected?.id == row.id && word.text.trimmingCharacters(in: .punctuationCharacters) == model.selectedWord ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 3))
                                    .help("Show the meaning of \(word.text)")
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .id(row.id)
                    }
                }
                .listStyle(.inset)
                .onChange(of: model.rows.last?.end) {
                    if followingLive, let id = model.rows.last?.id { scroll.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct CaptureSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.modelsReady ? "Capture dialogue" : "Set up speech recognition").font(.title2).fontWeight(.semibold)
                    Text(model.modelsReady ? "Choose your game in the macOS window picker." : "Choose a language and install the model that suits you.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Language").gridColumnAlignment(.trailing)
                    Picker("Language", selection: Binding(get: { model.language }, set: model.setCaptureLanguage)) {
                        ForEach(model.enabledLanguages, id: \.self) { Text($0.name).tag($0) }
                    }.labelsHidden().fixedSize().disabled(!model.canChangeTranscriptionModel)
                }
                GridRow {
                    Text("Game glossary")
                    GameGlossaryPicker(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Enable more languages…") { model.settingsPage = .languages; dismiss(); openSettings() }
                .buttonStyle(.link)
            if let status = model.languageStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if !model.rows.isEmpty { Text("A new capture replaces the current 30-minute buffer.").font(.caption).foregroundStyle(.secondary) }
            if !model.modelsReady {
                SpeechModelLibrary(model: model)
            } else {
                Label("\(model.transcriptionModel.name) is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                Button("Manage speech models…") { model.settingsPage = .speech; dismiss(); openSettings() }.buttonStyle(.link)
            }
            }.padding(24)
            }.frame(maxHeight: model.modelsReady ? 240 : 520)
            Divider()
            HStack {
                Text("Audio stays on your Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose game window…") { dismiss(); model.chooseWindow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.modelsReady || model.starting || model.choosingWindow)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .frame(width: 600)
    }
}

private struct WordInspector: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var screenshotImage: NSImage?
    var body: some View {
        if let selected = model.selected {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.learningWord ?? model.selectedWord).font(.title2).fontWeight(.semibold)
                        if let word = model.learningWord, word != model.selectedWord {
                            Text("In sentence: \(model.selectedWord)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(model.expiresIn).font(.caption).monospacedDigit().foregroundStyle(.secondary).help("Time left in the 30-minute buffer")
                    Button { model.dismissSelection() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Close word preview")
                }.padding(.horizontal, 20).padding(.vertical, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 8) {
                            if model.translating && model.learningWord == nil {
                                ProgressView().controlSize(.small)
                                Text("Preparing dictionary form…").font(.callout).foregroundStyle(.secondary)
                            } else if model.synthesizing {
                                ProgressView().controlSize(.small)
                                Text("Preparing word pronunciation…").font(.callout).foregroundStyle(.secondary)
                            } else if model.hasCurrentWordAudio {
                                Button(action: model.playWordAudio) { Label("Play word", systemImage: "speaker.wave.2") }
                                Text("Anki front").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button(model.hasReplicateToken ? "Generate word audio" : "Set up word audio…", action: model.generatePronunciation)
                                    .disabled(model.learningWord == nil || model.translating)
                            }
                        }
                        if let error = model.pronunciationError { Text(error).font(.caption).foregroundStyle(.red) }
                        if let image = screenshotImage {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity)
                        } else {
                            ContentUnavailableView("No matching image", systemImage: "photo", description: Text("The game window may have stopped drawing in the background.")).frame(height: 150)
                        }
                        HStack {
                            Button { model.frameIndex -= 1 } label: { Label("Previous frame", systemImage: "chevron.left") }.disabled(model.frameIndex <= 0)
                            Spacer()
                            if let frame = model.chosenFrame { Text(frame.date, style: .time).foregroundStyle(.secondary) }
                            Spacer()
                            Button { model.frameIndex += 1 } label: { Label("Next frame", systemImage: "chevron.right") }.disabled(model.frameIndex + 1 >= model.frames.count)
                        }.font(.caption).buttonStyle(.borderless).labelStyle(.iconOnly)
                        if model.translating {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing English…").font(.callout).foregroundStyle(.secondary) }
                        }
                        field("Dictionary form", text: $model.dictionaryForm)
                        Text("Single words use this form on the Anki card and in word audio. Selected phrases stay unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                        field("Meaning in this sentence", text: $model.definition)
                        Divider()
                        field("Original sentence", text: $model.sentence)
                        field("English translation", text: $model.sentenceTranslation)
                        HStack {
                            Button(action: model.playClip) { Label("Play sentence", systemImage: "play.fill") }
                            Spacer()
                            Text("\(selected.end - selected.start, specifier: "%.1f") s").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Regenerate English", action: model.explainSelection).controlSize(.small).disabled(model.translating)
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    if let message = model.exportStatus { Label(message, systemImage: "checkmark.circle").font(.caption) }
                    else if let target = model.ankiTargetForSelection { Text(target.deckName).font(.caption).foregroundStyle(.secondary).lineLimit(1).help("\(target.profileName) · \(target.noteTypeName)") }
                    if model.ankiTargetForSelection == nil { Button("Configure Anki…") { model.settingsPage = .anki; openSettings() }.buttonStyle(.borderless) }
                    Spacer()
                    if model.sending { ProgressView().controlSize(.small) }
                    Button("Send to Anki", action: model.sendToAnki).buttonStyle(.borderedProminent).disabled(!model.canSend)
                }.padding(16).frame(maxWidth: .infinity).background(.bar)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: model.chosenFrame?.id) {
                screenshotImage = model.chosenFrame.flatMap { NSImage(contentsOf: $0.url) }
            }
        }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, axis: .vertical).textFieldStyle(.roundedBorder)
        }
    }
}

struct WordFlowLayout: Layout {
    var spacing: CGFloat
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (CGSize, [CGPoint]) {
        var positions: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), positions)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { arrange(subviews, width: proposal.width ?? 400).0 }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).1
        for (index, view) in subviews.enumerated() { view.place(at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y), proposal: .unspecified) }
    }
}

struct PronunciationKeyView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Word pronunciation").font(.title2).fontWeight(.semibold)
            Text("Generate word pronunciation with \(model.pronunciationModel.name) on Replicate.")
            SecureField("Replicate API key", text: $token).textFieldStyle(.roundedBorder).onSubmit(save)
            Link("Get a Replicate API key", destination: URL(string: "https://replicate.com/account/api-tokens")!)
            Text("Your key is stored in macOS Keychain. Only the selected word is sent to Replicate and your selected voice provider. You can change the audio model in Settings.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { token = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.selected == nil ? "Save key" : "Save and generate", action: save)
                    .keyboardShortcut(.defaultAction).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440)
    }
    private func save() {
        do { try model.saveReplicateKey(token); token = ""; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
