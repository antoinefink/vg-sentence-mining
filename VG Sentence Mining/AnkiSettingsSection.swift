import MiningCore
import SwiftUI

struct AnkiSettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var language: GameLanguage = .german
    @State private var showingMapping = false

    private var target: Binding<AnkiNoteConfiguration> {
        Binding(get: { model.ankiTargets[language] ?? AnkiNoteConfiguration(profileName: "", deckName: "", noteTypeName: "", mapping: [:]) },
                set: { model.updateAnkiConfiguration($0, for: language) })
    }

    var body: some View {
        Section("Anki") {
            HStack {
                Button("Refresh decks and note types", systemImage: "arrow.clockwise", action: model.refreshAnki)
                    .disabled(model.refreshingAnki)
                if model.refreshingAnki { ProgressView().controlSize(.small) }
            }
            if let catalog = model.ankiCatalog {
                LabeledContent("Profile", value: catalog.profileName)
                Group {
                    Picker("Configure for", selection: $language) {
                        ForEach(GameLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    Picker("Deck", selection: target.deckName) {
                        Text("Choose a deck…").tag("")
                        ForEach(catalog.decks, id: \.self) { Text($0).tag($0) }
                        if !target.wrappedValue.deckName.isEmpty, !catalog.decks.contains(target.wrappedValue.deckName) {
                            Text("Missing: \(target.wrappedValue.deckName)").tag(target.wrappedValue.deckName)
                        }
                    }
                    Picker("Note type", selection: target.noteTypeName) {
                        Text("Choose a note type…").tag("")
                        ForEach(catalog.noteTypes, id: \.self) { Text($0).tag($0) }
                        if !target.wrappedValue.noteTypeName.isEmpty, !catalog.noteTypes.contains(target.wrappedValue.noteTypeName) {
                            Text("Missing: \(target.wrappedValue.noteTypeName)").tag(target.wrappedValue.noteTypeName)
                        }
                    }
                    if model.loadingAnkiFields.contains(language) {
                        HStack { ProgressView().controlSize(.small); Text("Reading note fields…") }
                    } else if let fields = model.ankiFields[target.wrappedValue.noteTypeName] {
                        DisclosureGroup("Field mapping", isExpanded: $showingMapping) {
                            ForEach(AnkiFieldRole.allCases.filter { !$0.isAutomatic }, id: \.self) { role in
                                Picker(role.title, selection: fieldBinding(role)) {
                                    Text(role.required ? "Choose a field…" : "Do not export").tag("")
                                    ForEach(fields, id: \.self) { Text($0).tag($0) }
                                    if let current = target.wrappedValue.mapping[role], !current.isEmpty, !fields.contains(current) {
                                        Text("Missing: \(current)").tag(current)
                                    }
                                }
                            }
                            Button("Use suggested mapping") { model.suggestAnkiMapping(for: language) }
                        }
                    }
                }.disabled(model.refreshingAnki)
                Text("Save keeps separate choices for each language and Anki profile. Your selected note type controls the card layout.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.ankiError { Text(error).font(.caption).foregroundStyle(.red) }
            else if let status = model.ankiStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .task { language = model.language; model.refreshAnki() }
    }

    private func fieldBinding(_ role: AnkiFieldRole) -> Binding<String> {
        Binding(get: { target.wrappedValue.mapping[role] ?? "" }, set: { value in
            var configuration = target.wrappedValue
            if value.isEmpty { configuration.mapping.removeValue(forKey: role) }
            else { configuration.mapping[role] = value }
            target.wrappedValue = configuration
        })
    }
}
