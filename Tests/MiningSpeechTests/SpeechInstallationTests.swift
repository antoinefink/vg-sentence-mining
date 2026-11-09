import Foundation
import MiningCore
@testable import MiningSpeech
import Testing

@Test func cancellingADownloadStopsTheInstallerProcessPromptly() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: log) }
    try Data().write(to: log)
    let runner = InstallProcess()
    let (updates, continuation) = AsyncStream<SpeechInstallProgress>.makeStream()
    defer { continuation.finish() }
    let task = Task {
        try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                             ["-c", "printf '%s\\n' '{\"message\":\"started\"}'; exec /bin/sleep 30"],
                             environment: nil, log: log) { continuation.yield($0) }
    }
    var iterator = updates.makeAsyncIterator()
    let update = await iterator.next()
    #expect(update?.message == "started")
    let start = Date()
    runner.cancel()
    do {
        try await task.value
        Issue.record("Cancellation must stop the installer.")
    } catch { #expect(error is CancellationError) }
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func interruptedInstallationDoesNotReplaceTheWorkingInterpreter() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let isolated = root.appendingPathComponent("Environments/parakeet-ultra/.venv/bin/python")
    try FileManager.default.createDirectory(at: isolated.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: isolated)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: isolated.path)
    #expect(SpeechInstallation.python(runtime: root, model: .parakeetUltra) == root.appendingPathComponent(".venv/bin/python"))
    let manifest: [String: Any] = ["protocol": 1, "environments": ["parakeet-ultra": "Environments/parakeet-ultra/.venv/bin/python"]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    #expect(SpeechInstallation.python(runtime: root, model: .parakeetUltra) == isolated)
    #expect(SpeechInstallation.python(runtime: root, model: .whisperLargeV3) == root.appendingPathComponent(".venv/bin/python"))
}

@Test func installedStatusRequiresTheSelectedModelsAndQwenAligner() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directories = SpeechDirectories(directory: root)
    let bin = directories.runtimeDirectory.appendingPathComponent(".venv/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let python = bin.appendingPathComponent("python")
    try Data("#!/bin/sh\n".utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let manifest: [String: Any] = ["protocol": 1, "models": [
        "qwen3-asr-1.7b": ["path": "qwen3-asr-1.7b/rev", "revision": "rev"],
        "qwen3-aligner": ["path": "qwen3-aligner/rev", "revision": "rev"]]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: directories.runtimeDirectory.appendingPathComponent("manifest.json"))
    try FileManager.default.createDirectory(at: directories.modelsDirectory.appendingPathComponent("qwen3-asr-1.7b/rev"), withIntermediateDirectories: true)
    #expect(!SpeechInstallation.isInstalled(.qwen3ASR, in: directories))
    try FileManager.default.createDirectory(at: directories.modelsDirectory.appendingPathComponent("qwen3-aligner/rev"), withIntermediateDirectories: true)
    #expect(SpeechInstallation.isInstalled(.qwen3ASR, in: directories))
    #expect(!SpeechInstallation.isInstalled(.whisperLargeV3, in: directories))
    try FileManager.default.removeItem(at: python)
    #expect(!SpeechInstallation.isInstalled(.qwen3ASR, in: directories))
}

@Test func modelInstallationIntegration() async throws {
    guard ProcessInfo.processInfo.environment["VG_INSTALL_INTEGRATION"] == "1" else { return }
    let directories = SpeechDirectories.load(
        defaults: UserDefaults(suiteName: "io.antoine.vg-sentence-mining") ?? .standard,
        environment: ProcessInfo.processInfo.environment)
    let otherModels = Set(TranscriptionModel.allCases.filter { $0 != .parakeetUltra && SpeechInstallation.isInstalled($0, in: directories) })
    try await SpeechModelInstaller().install(.parakeetUltra, in: directories) { progress in
        print(progress.message)
    }
    #expect(SpeechInstallation.isInstalled(.parakeetUltra, in: directories))
    #expect(Set(TranscriptionModel.allCases.filter { $0 != .parakeetUltra && SpeechInstallation.isInstalled($0, in: directories) }) == otherModels)
    let engine = LocalSpeechEngine()
    try await engine.prepare(modelDirectory: directories.modelsDirectory, model: .parakeetUltra)
    let silent = try await engine.transcribe(Array(repeating: 0, count: 16000), language: .german)
    #expect(silent.isEmpty)
    await engine.unload()
}
