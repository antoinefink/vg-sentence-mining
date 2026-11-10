import MiningCore
import SwiftUI

enum SettingsPage: String, CaseIterable {
    case speech = "Speech", languages = "Languages", anki = "Anki", assistance = "Assistance"
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showingKeySetup = false
    @State private var voiceTestLanguage: GameLanguage = .german

    var body: some View {
        TabView(selection: $model.settingsPage) {
            Tab("Speech", systemImage: "waveform", value: .speech) {
                Form {
                    Section("Transcription") { SpeechModelLibrary(model: model) }
                }
            }
            Tab("Languages", systemImage: "globe", value: .languages) {
                Form {
                    LanguageSettingsSection(model: model)
                    GameGlossarySettingsSection(model: model)
                }
            }
            Tab("Anki", systemImage: "rectangle.stack", value: .anki) {
                Form {
                    AnkiSettingsSection(model: model)
                    if model.ankiCatalog != nil { saveControls }
                }
            }
            Tab("Assistance", systemImage: "text.bubble", value: .assistance) {
                Form {
                    Section("Language assistance") {
                        TextField("Codex CLI", text: $model.codexPath)
                        Text("Codex uses your existing login. Selected text is sent to its OpenAI service; game audio stays local.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    pronunciationSection
                    saveControls
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 700)
        .sheet(isPresented: $showingKeySetup) { PronunciationKeyView(model: model) }
        .onAppear { voiceTestLanguage = model.language }
        .onChange(of: model.enabledLanguages) {
            if !model.enabledLanguages.contains(voiceTestLanguage) { voiceTestLanguage = model.language }
        }
        .onChange(of: model.settingsPage) { model.stopVoiceTest() }
        .onDisappear { model.stopVoiceTest() }
    }

    private var pronunciationSection: some View {
        Section("Word pronunciation") {
            Picker("Model", selection: $model.pronunciationModel) {
                ForEach(PronunciationModel.allCases, id: \.self) { choice in
                    Text(choice.name).tag(choice)
                        .disabled(!choice.supports(model.language) || !choice.supports(model.selected?.language ?? model.language))
                }
            }
            Text(model.pronunciationModel.detail + " Changes apply immediately.").font(.caption).foregroundStyle(.secondary)
            if model.hasReplicateToken {
                Label("API key saved in Keychain", systemImage: "key.fill")
                HStack {
                    Button("Replace API key…") { showingKeySetup = true }
                    Button("Remove API key", role: .destructive, action: model.removeReplicateKey)
                }
                LabeledContent("Test language") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Picker("Test language", selection: $voiceTestLanguage) {
                            ForEach(model.enabledLanguages, id: \.self) { Text($0.name).tag($0) }
                        }.labelsHidden().frame(width: 160)
                        Button("Test voice") { model.testVoice(voiceTestLanguage) }
                            .fixedSize()
                            .disabled(!model.pronunciationModel.supports(voiceTestLanguage))
                        if model.testingVoice { ProgressView().controlSize(.small) }
                    }.controlSize(.regular).disabled(model.testingVoice)
                }
                if !model.pronunciationModel.supports(voiceTestLanguage) {
                    Text("Choose another pronunciation model to test \(voiceTestLanguage.name).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let status = model.voiceTestStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            } else {
                Button("Set up Replicate…") { showingKeySetup = true }
            }
        }
    }

    @ViewBuilder private var saveControls: some View {
        Button("Save", action: model.saveSettings)
            .disabled(model.refreshingAnki || !model.loadingAnkiFields.isEmpty)
        if let status = model.settingsStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
    }
}
