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
    printf '%s\\n' '{"kind":"ready","protocol":1,"model":"parakeet-ultra","glossarySupported":false}'
    exit 0
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let worker = try SpeechWorker(runtime: runtime, model: .parakeetUltra)
    try await worker.start()
    try await Task.sleep(for: .milliseconds(50))
    await #expect(throws: (any Error).self) {
        try await worker.transcribe(Array(repeating: 0.1, count: 16000), language: .german, glossary: [])
    }
    await worker.shutdown()
}
