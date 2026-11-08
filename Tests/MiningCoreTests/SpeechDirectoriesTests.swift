import Foundation
import Testing
@testable import MiningCore

@Test func oneSpeechFolderSavesAndRestoresBothModelAndRuntimeLocations() throws {
    let suite = "speech-folders-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let initial = SpeechDirectories.load(defaults: defaults)
    #expect(initial.modelsDirectory.path.contains("Library/Application Support/VG Sentence Mining/Models"))
    #expect(initial.runtimeDirectory.lastPathComponent == "SpeechRuntime")
    let selected = SpeechDirectories(directory: URL(fileURLWithPath: "/Volumes/External Disk/Speech"))
    selected.save(defaults: defaults)
    #expect(SpeechDirectories.load(defaults: defaults) == selected)
    let overridden = SpeechDirectories.load(defaults: defaults, environment: [
        "VG_SPEECH_DIRECTORY": "/tmp/moved-speech"
    ])
    #expect(overridden.modelsDirectory.path == "/tmp/moved-speech/Models")
    #expect(overridden.runtimeDirectory.path == "/tmp/moved-speech/SpeechRuntime")
    #expect(SpeechDirectories.load(defaults: defaults) == selected)
}

@Test func oneSpeechFolderKeepsModelsAndEngineFilesTogether() {
    let folders = SpeechDirectories(directory: URL(fileURLWithPath: "/Volumes/Another Drive/Speech"))
    #expect(folders.modelsDirectory.path == "/Volumes/Another Drive/Speech/Models")
    #expect(folders.runtimeDirectory.path == "/Volumes/Another Drive/Speech/SpeechRuntime")
}
