import MiningCore
import SwiftUI

struct LanguageSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Enabled languages") {
            Text("Enable the languages you want to learn. Your choices save automatically and appear in the capture and Anki menus.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(GameLanguage.allCases, id: \.self) { language in
                    Toggle(language.name, isOn: Binding(
                        get: { model.enabledLanguages.contains(language) },
                        set: { model.setLanguageEnabled(language, enabled: $0) }))
                        .toggleStyle(.checkbox)
                        .disabled(model.enabledLanguages == [language])
                }
            }.disabled(!model.canChangeTranscriptionModel || model.refreshingAnki)
            Text("Keep at least one language enabled. Stop capture before changing this list. Existing Anki cards and saved deck choices stay available.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = model.languageStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
