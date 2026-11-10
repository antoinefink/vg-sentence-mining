import MiningCore
import SwiftUI

struct GameGlossaryPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Picker("Game glossary", selection: $model.glossaryPreferences.selectedID) {
                Text("No glossary").tag(nil as UUID?)
                ForEach(model.glossaryPreferences.presets) { preset in
                    Text(preset.displayTitle).tag(Optional(preset.id))
                }
            }
            Divider()
            Button("Edit glossaries…") { model.settingsPage = .languages; openSettings() }
        } label: {
            Text(model.transcriptionModel.supportsGlossary ? (model.glossaryPreferences.selected?.displayTitle ?? "No glossary") : "Glossary unavailable")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 180, alignment: .leading)
        .accessibilityLabel("Game glossary")
        .accessibilityValue(model.transcriptionModel.supportsGlossary ? (model.glossaryPreferences.selected?.displayTitle ?? "No glossary") : "Not used by Parakeet Ultra")
        .help(model.transcriptionModel.supportsGlossary ? "Choose a glossary for new dialogue" : "Parakeet Ultra does not use glossary hints. Select Whisper or Qwen in Settings to use this glossary.")
    }
}

struct GameGlossarySettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var editingID: UUID?

    var body: some View {
        Section("Game glossaries") {
            if !model.transcriptionModel.supportsGlossary {
                Text("Parakeet Ultra does not use glossary hints. Your presets stay saved for Whisper and Qwen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.glossaryPreferences.presets.isEmpty {
                Text("Save a short glossary for each game to help recognize names, places and unusual terms.")
                    .foregroundStyle(.secondary)
                Button("Add glossary", systemImage: "plus", action: add)
            } else {
                HStack {
                    Picker("Preset", selection: $editingID) {
                        ForEach(model.glossaryPreferences.presets) { preset in
                            Text(preset.displayTitle).tag(Optional(preset.id))
                        }
                    }
                    Button(action: add) { Image(systemName: "plus") }
                        .accessibilityLabel("Add glossary")
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .accessibilityLabel("Delete glossary").disabled(editingID == nil)
                }
                if let preset = model.glossaryPreferences.presets.first(where: { $0.id == editingID }) {
                    TextField("Title", text: binding(preset.id, \.title), prompt: Text("Game name"))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Glossary").font(.callout)
                        TextEditor(text: binding(preset.id, \.text))
                            .font(.body)
                            .autocorrectionDisabled()
                            .frame(minHeight: 140, idealHeight: 180, maxHeight: 240)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator, lineWidth: 1))
                            .accessibilityLabel("Glossary terms")
                        Text("Paste words or phrases, one per line. Bullets, commas, semicolons and tabs also work.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("\(preset.terms.count) terms · Saved automatically")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if model.glossaryPreferences.selectedID == preset.id {
                                Label("Current glossary", systemImage: "checkmark")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Use this glossary") { model.glossaryPreferences.selectedID = preset.id }
                            }
                        }
                    }
                }
                Picker("Use for capture", selection: $model.glossaryPreferences.selectedID) {
                    Text("No glossary").tag(nil as UUID?)
                    ForEach(model.glossaryPreferences.presets) { preset in
                        Text(preset.displayTitle).tag(Optional(preset.id))
                    }
                }
                Text("Shared by all languages. Use about 5–10 unusual names or places. Hints use up to 32 entries and 512 characters from the start of the list. Changes apply to new dialogue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { selectEditor() }
        .onChange(of: model.glossaryPreferences.presets.map(\.id)) { selectEditor() }
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<GameGlossary, String>) -> Binding<String> {
        Binding {
            model.glossaryPreferences.presets.first { $0.id == id }?[keyPath: keyPath] ?? ""
        } set: { value in
            guard let index = model.glossaryPreferences.presets.firstIndex(where: { $0.id == id }) else { return }
            model.glossaryPreferences.presets[index][keyPath: keyPath] = value
        }
    }

    private func selectEditor() {
        if !model.glossaryPreferences.presets.contains(where: { $0.id == editingID }) {
            editingID = model.glossaryPreferences.selected?.id ?? model.glossaryPreferences.presets.first?.id
        }
    }

    private func add() {
        let preset = GameGlossary()
        model.glossaryPreferences.presets.append(preset)
        editingID = preset.id
        model.glossaryPreferences.selectedID = preset.id
    }

    private func remove() {
        guard let editingID else { return }
        model.glossaryPreferences.remove(id: editingID)
        selectEditor()
    }
}
