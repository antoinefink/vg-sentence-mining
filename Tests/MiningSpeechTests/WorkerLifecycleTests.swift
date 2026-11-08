import Foundation
import MiningCore
@testable import MiningSpeech
import Testing

@Test func exitedSpeechWorkerReportsAnErrorWithoutCrashingTheApp() async throws {
    let runtime = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runtime) }
    let bin = runtime.appendingPathComponent(".venv/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let executable = bin.appendingPathComponent("python")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "${0%/.venv/bin/python}/arguments.txt"
    printf '%s\\n' '{"kind":"ready","protocol":1,"model":"parakeet-ultra","glossarySupported":false}'
    exit 0
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let models = runtime.appendingPathComponent("Selected Models", isDirectory: true)
    let worker = try SpeechWorker(runtime: runtime, models: models, model: .parakeetUltra)
    try await worker.start()
    let arguments = try String(contentsOf: runtime.appendingPathComponent("arguments.txt"), encoding: .utf8)
        .components(separatedBy: "\n")
    let modelsFlag = try #require(arguments.firstIndex(of: "--models"))
    #expect(arguments[modelsFlag + 1] == models.path)
    try await Task.sleep(for: .milliseconds(50))
    await #expect(throws: (any Error).self) {
        try await worker.transcribe(Array(repeating: 0.1, count: 16000), language: .german, glossary: [])
    }
    await worker.shutdown()
}

@Test func missingModelsFolderReportsTheConfiguredFolderProblem() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        try await LocalSpeechEngine().prepare(modelDirectory: missing)
        Issue.record("A missing models folder must not load.")
    } catch {
        #expect(error.localizedDescription.contains("models folder"))
        #expect(error.localizedDescription.contains("Settings"))
    }
}
