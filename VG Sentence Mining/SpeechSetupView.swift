import AppKit
import MiningCore
import SwiftUI

struct SpeechModelLibrary: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.badge.mic")
                    .font(.title2).foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech recognition on your Mac").font(.headline)
                    Text("Install one model to get started. Add others whenever you need them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if model.recording || model.starting || model.stopping || model.choosingWindow {
                Label("Stop capture before changing speech models or their location.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.installingModel != nil, let progress = model.installationProgress {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(progress.message).font(.callout).fontWeight(.medium)
                        Spacer()
                        Button("Cancel", action: model.cancelInstallation)
                            .disabled(progress.message == "Cancelling installation…")
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                        if let completed = progress.completed, let total = progress.total {
                            Text("\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    } else { ProgressView().controlSize(.small) }
                    Text("You can close this panel. Keep the app open to finish the installation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
            }
            if model.loadingModels {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Preparing \(model.transcriptionModel.name)…").font(.callout)
                        Text("The first load also downloads shared speech detection files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            if let error = model.installationError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Installation needs attention", systemImage: "exclamationmark.triangle")
                        .font(.callout).fontWeight(.medium)
                    Text(error).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Retry installation") { model.installModel(model.transcriptionModel) }
                            .disabled(!model.canChangeTranscriptionModel)
                        Button("Show installation log") {
                            NSWorkspace.shared.open(model.speechDirectories.runtimeDirectory.appendingPathComponent("Logs/installation.log"))
                        }.buttonStyle(.link)
                    }
                }
                .foregroundStyle(.primary).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(TranscriptionModel.allCases, id: \.self) { choice in
                modelCard(choice)
            }
            SpeechFolderView(model: model)
            Text("Downloads need an internet connection and can take several minutes. Recognition then runs locally.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshInstalledModels() }
    }

    private func modelCard(_ choice: TranscriptionModel) -> some View {
        let installed = model.installedModels.contains(choice)
        let selected = model.transcriptionModel == choice
        let compatible = choice.supports(model.language)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(choice.name).font(.headline)
                    if choice.isExperimental { badge("Experimental", color: .orange) }
                    else if choice == (TranscriptionModel.parakeetUltra.supports(model.language) ? .parakeetUltra : .whisperLargeV3) {
                        badge("Recommended", color: .accentColor)
                    }
                }
                Text(choice.downloadDetail).font(.caption).foregroundStyle(.secondary)
                if !compatible {
                    Text("Unavailable for \(model.language.name)").font(.caption).foregroundStyle(.secondary)
                } else if installed {
                    Label(selected && model.modelsReady ? "Ready to capture" : "Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Text(choice == .parakeetUltra ? "17 languages. Choose Whisper for glossary hints." : choice.detail.replacingOccurrences(of: "Experimental. ", with: ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.installingModel == choice {
                ProgressView().controlSize(.small).frame(width: 76)
            } else if selected && model.modelsReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.title3).frame(width: 76)
                    .accessibilityLabel("Selected model")
            } else {
                Button(installed ? (selected ? "Load" : "Use model") : "Install") {
                    if installed {
                        if selected { model.loadModels() } else { model.setTranscriptionModel(choice) }
                    } else { model.installModel(choice) }
                }
                .buttonStyle(.bordered).controlSize(.regular).frame(minWidth: 76)
                .disabled(!compatible || !model.canChangeTranscriptionModel)
                .accessibilityLabel("\(installed ? "Load" : "Install") \(choice.name)")
            }
        }
        .padding(14)
        .background(selected ? Color.accentColor.opacity(0.055) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.09)))
        .accessibilityElement(children: .contain)
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title).font(.caption2).fontWeight(.medium).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct SpeechFolderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Speech folder", systemImage: "folder").font(.callout).fontWeight(.medium)
                Spacer()
                if model.speechDirectories.directory != SpeechDirectories.defaultDirectory {
                    Button("Use default", action: model.useDefaultSpeechFolder).buttonStyle(.link)
                }
                Button("Change…", action: model.chooseSpeechFolder)
            }
            Text((model.speechDirectories.directory.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled).help(model.speechDirectories.directory.path)
            Text("Use the default location, or choose a folder on another disk. Existing downloads stay in their original folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.canChangeTranscriptionModel)
        .padding(.top, 4)
    }
}
