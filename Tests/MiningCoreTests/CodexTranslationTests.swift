import Foundation
import Testing
@testable import MiningCore

struct CodexTranslationTests {
    @Test func launchesNodeBasedCLIWithoutATerminalPATH() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shims = home.appendingPathComponent(".asdf/shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let node = shims.appendingPathComponent("node")
        try Data("#!/bin/sh\necho runtime-found\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let cli = home.appendingPathComponent("codex")
        try Data("#!/usr/bin/env node\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let process = Process()
        process.executableURL = cli
        process.environment = CodexTranslator.launchEnvironment(executable: cli.path, inherited: ["PATH": "/usr/bin:/bin", "HOME": home.path], home: home)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "runtime-found\n")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VG_CODEX_INTEGRATION"] == "1"), arguments: [
        ("Kaisers", "Der Kontakt des Hexers in Velen sollte Hendrik sein, ein Spion des Kaisers, der in dem dem kriegsversehrten Land inkognito operierte.", "der kaiser"),
        ("Auftrag", "Sein Auftrag lautete, Informationen über Ciri zu beschaffen.", "der auftrag"),
        ("verwest", "Ich hoffe, dass seine Leiche nicht in der Sonne verwest.", "verwesen"),
        ("Häusern", "Wir wohnen in großen Häusern.", "das haus"),
        ("grünen", "Sie sitzt auf dem grünen Stuhl.", "grün"),
        ("Ciri", "Wir suchen Ciri.", "ciri")
    ])
    func installedCLIUsesDictionaryFormsInContext(word: String, sentence: String, expected: String) async throws {
        let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/codex").path
        let result = try await CodexTranslator().explain(
            word: word, sentence: sentence,
            language: .german, executable: cli)
        #expect(result.dictionaryForm.lowercased() == expected)
        #expect(!result.definition.isEmpty)
        #expect(!result.sentenceTranslation.isEmpty)
    }

    private func withCLI<T>(_ script: String, run: (String) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\ncat >/dev/null\n\(script)\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return try await run(cli.path)
    }

    private func explain(_ executable: String, translator: CodexTranslator = CodexTranslator()) async throws -> WordExplanation {
        try await translator.explain(word: "Kaisers", sentence: "Ein Spion des Kaisers.", language: .german, executable: executable)
    }

    @Test func failedCLIReportsTheExitCodeWithoutGuessingLoginOrExposingOutput() async throws {
        try await withCLI("echo 'private dialogue and credentials' >&2\nexit 23") { cli in
            do {
                _ = try await explain(cli)
                Issue.record("A failed CLI must not return an explanation")
            } catch {
                #expect(error.localizedDescription.contains("23"))
                #expect(!error.localizedDescription.contains("login"))
                #expect(!error.localizedDescription.contains("private dialogue"))
                #expect(!error.localizedDescription.contains("credentials"))
            }
        }
    }

    @Test(arguments: [
        ("ERROR: authentication failed: private-token", "codex login"),
        ("ERROR: Rate limit reached: private-account", "usage limit"),
        ("ERROR: error sending request: private-url", "connection"),
        ("Quoted data: unauthorized, rate limit, stream disconnected", "code 23")
    ])
    func classifiesOnlyCLIErrorsWithoutExposingDetails(diagnostic: String, expected: String) async throws {
        try await withCLI("echo '\(diagnostic)' >&2\nexit 23") { cli in
            do {
                _ = try await explain(cli)
                Issue.record("A failed CLI must not return an explanation")
            } catch {
                #expect(error.localizedDescription.contains(expected))
                #expect(!error.localizedDescription.contains("private-"))
            }
        }
    }

    @Test func timeoutIsDistinctFromAuthenticationFailure() async throws {
        try await withCLI("exec /bin/sleep 10") { cli in
            let started = ContinuousClock.now
            do {
                _ = try await explain(cli, translator: CodexTranslator(timeout: 0.1))
                Issue.record("The request must time out")
            } catch {
                #expect(error.localizedDescription.contains("too long"))
                #expect(!error.localizedDescription.contains("login"))
            }
            #expect(started.duration(to: .now) < .seconds(5))
        }
    }

    @Test func cancellationIsNotPresentedAsATranslationFailure() async throws {
        try await withCLI("exec /bin/sleep 10") { cli in
            let task = Task { try await explain(cli) }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test(arguments: [("exit 0", "without a translation"), ("echo invalid > \"$output\"", "unreadable translation")])
    func missingAndMalformedOutputHaveUsefulErrors(script: String, expected: String) async throws {
        try await withCLI("while [ $# -gt 0 ]; do\nif [ \"$1\" = '--output-last-message' ]; then shift; output=$1; fi\nshift\ndone\n\(script)") { cli in
            do {
                _ = try await explain(cli)
                Issue.record("Missing or invalid output must fail")
            } catch {
                #expect(error.localizedDescription.contains(expected))
            }
        }
    }

    @Test func validResponseStillDecodesAfterLargeDiagnostics() async throws {
        let script = #"""
        while [ $# -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then shift; output=$1; fi
          shift
        done
        /usr/bin/yes 'diagnostic line' | /usr/bin/head -c 100000 >&2
        echo '{"dictionaryForm":"Kaiser","definition":"emperor","sentenceTranslation":"A spy for the emperor."}' > "$output"
        """#
        try await withCLI(script) { cli in
            let result = try await explain(cli)
            #expect(result.dictionaryForm == "Kaiser")
            #expect(result.definition == "emperor")
            #expect(result.sentenceTranslation == "A spy for the emperor.")
        }
    }
}
