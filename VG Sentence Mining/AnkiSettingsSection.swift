import AppKit
import MiningCore
import SwiftUI

struct AnkiSettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var language: GameLanguage = .german
    @State private var showingMapping = true

    private var target: Binding<AnkiNoteConfiguration> {
        Binding(get: { model.ankiTargets[language] ?? AnkiNoteConfiguration(profileName: "", deckName: "", noteTypeName: "", mapping: [:]) },
                set: { model.updateAnkiConfiguration($0, for: language) })
    }

    private var exportRoles: [AnkiFieldRole] { AnkiFieldRole.allCases.filter { !$0.isAutomatic } }

    private var sharedFields: [(field: String, roles: [AnkiFieldRole])] {
        let mapping = target.wrappedValue.mapping
        var seen = Set<String>()
        return exportRoles.compactMap { role in
            guard let field = mapping[role], !field.isEmpty, seen.insert(field).inserted else { return nil }
            let roles = exportRoles.filter { mapping[$0] == field }
            return roles.count > 1 ? (field, roles) : nil
        }
    }

    var body: some View {
        Group {
            if let catalog = model.ankiCatalog {
                Section {
                    LabeledContent("Profile", value: catalog.profileName)
                    selectionRow("Configure for", value: language.name, selection: $language,
                                 options: model.enabledLanguages, titleFor: { $0.name })
                    fieldPicker("Deck", selection: target.deckName, options: catalog.decks, placeholder: "Choose a deck…")
                    fieldPicker("Note type", selection: target.noteTypeName, options: catalog.noteTypes, placeholder: "Choose a note type…")
                    HStack {
                        Button("Refresh decks and note types", systemImage: "arrow.clockwise", action: model.refreshAnki)
                        if model.refreshingAnki { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("Export destination")
                } footer: {
                    Text("Click Save to keep these choices for this language and Anki profile. The note type controls the card layout.")
                }
                .disabled(model.refreshingAnki)

                if model.loadingAnkiFields.contains(language) {
                    Section { HStack { ProgressView().controlSize(.small); Text("Reading note fields…") } }
                } else if let fields = model.ankiFields[target.wrappedValue.noteTypeName] {
                    mappingSection(fields: fields)
                        .disabled(model.refreshingAnki)
                }
                if let error = model.ankiError {
                    Section { Text(error).font(.callout).foregroundStyle(.red) }
                }
            } else {
                Section("Connection") { connectionControls }
            }
        }
        .task { language = model.language; model.refreshAnki() }
        .onChange(of: model.enabledLanguages) {
            if !model.enabledLanguages.contains(language) { language = model.language }
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect to Anki", systemImage: "rectangle.stack.badge.plus")
                .font(.headline)
            Text("Open Anki with AnkiConnect enabled, then connect to choose your decks and note types.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Connect to Anki", action: model.refreshAnki)
                    .buttonStyle(.borderedProminent).disabled(model.refreshingAnki)
                if model.refreshingAnki { ProgressView().controlSize(.small) }
            }
            if model.ankiError != nil {
                Text("Anki is not available yet. Keep Anki open and check that AnkiConnect is installed.")
                    .font(.caption).foregroundStyle(.secondary).help(model.ankiError ?? "")
            }
            Text("Connecting only reads your settings. Cards are created when you choose Send to Anki.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func mappingSection(fields: [String]) -> some View {
        Section {
            Button {
                showingMapping.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showingMapping ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text("Field mapping").font(.headline)
                    Spacer()
                    Text(showingMapping ? "Hide" : "Show").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showingMapping ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide Anki field choices")

            if showingMapping {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Choose the Anki field for each item. Choose “Do not export” to leave out an optional item.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !sharedFields.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Combined fields", systemImage: "text.badge.plus").font(.callout.weight(.medium))
                            ForEach(sharedFields, id: \.field) { group in
                                Text("\(group.field): \(group.roles.map(\.title).joined(separator: " + "))")
                            }
                            Text("Text in a shared field appears on separate lines, in the order above.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                    ForEach(exportRoles, id: \.self) { role in
                        fieldPicker(role.title, selection: fieldBinding(role), options: fields,
                                    placeholder: role.required ? "Choose a field…" : "Do not export")
                    }
                    HStack {
                        Spacer()
                        Button("Use suggested mapping") { model.suggestAnkiMapping(for: language) }
                    }
                }
            }
        }
    }

    private func fieldPicker(_ title: String, selection: Binding<String>, options: [String], placeholder: String) -> some View {
        let current = selection.wrappedValue
        let missing = !current.isEmpty && !options.contains(current)
        let value = current.isEmpty ? placeholder : missing ? "Missing: \(current)" : current
        return selectionRow(title, value: value, selection: selection,
                            options: [""] + options + (missing ? [current] : []),
                            titleFor: { $0.isEmpty ? placeholder : missing && $0 == current ? "Missing: \($0)" : $0 })
    }

    private func selectionRow<Value: Hashable>(_ title: String, value: String, selection: Binding<Value>, options: [Value], titleFor: @escaping (Value) -> String) -> some View {
        LabeledContent(title) {
            AnkiChoiceControl(title: title, choices: options.map(titleFor), selectedIndex: Binding(
                get: { options.firstIndex(of: selection.wrappedValue) ?? 0 },
                set: { if options.indices.contains($0) { selection.wrappedValue = options[$0] } }
            ))
            .frame(width: 250, height: 32)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
            .help(value)
        }
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

// Padding a SwiftUI Picker leaves blank space unclickable; the native popup uses its full frame.
private struct AnkiChoiceControl: NSViewRepresentable {
    let title: String
    let choices: [String]
    @Binding var selectedIndex: Int

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .large
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.control = self
        if button.itemTitles != choices {
            button.removeAllItems()
            button.addItems(withTitles: choices)
        }
        button.selectItem(at: selectedIndex)
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(button.titleOfSelectedItem)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var control: AnkiChoiceControl
        init(_ control: AnkiChoiceControl) { self.control = control }
        @objc func select(_ sender: NSPopUpButton) { control.selectedIndex = sender.indexOfSelectedItem }
    }
}
