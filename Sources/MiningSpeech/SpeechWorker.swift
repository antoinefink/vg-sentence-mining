import Foundation
import Darwin
import MiningCore

final class SpeechWorker: @unchecked Sendable {
    private struct Reply: Decodable {
        struct Word: Decodable { let text: String; let start: Double; let end: Double }
        var kind: String?
        var `protocol`: Int?
        var model: String?
        var glossarySupported: Bool?
        var id: String?
        var words: [Word]?
        var error: String?
    }
    private struct Request: Encodable {
        let id: String
        let audio: String
        let language: String
        let glossary: [String]
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lifecycle = NSLock()
    private let io = NSLock()
    private var stopped = false
    private var pending = Data()
    private let model: TranscriptionModel
    private let log: FileHandle
    private let logURL: URL

    init(runtime: URL, models: URL, model: TranscriptionModel) throws {
        self.model = model
        let python = SpeechInstallation.python(runtime: runtime, model: model)
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let script = Bundle.module.url(forResource: "speech_worker", withExtension: "py") else {
            throw MiningError.message("The speech engine is missing. Install \(model.name) in Settings → Transcription, or choose an existing speech folder.")
        }
        let logs = runtime.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("\(model.rawValue).log")
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 8 * 1024 * 1024 {
            let previous = logURL.appendingPathExtension("previous")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: logURL, to: previous)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        process.executableURL = python
        process.arguments = ["-u", script.path, "--runtime", runtime.path, "--models", models.path, "--model", model.rawValue]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw MiningError.message("Could not configure the local speech connection.")
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = log
    }

    deinit { stop(); try? log.close() }

    func start() async throws {
        try await operation(timeout: 120) {
            try self.launch()
            let reply = try self.readReply()
            guard reply.error == nil, reply.kind == "ready", reply.protocol == 1, reply.model == self.model.rawValue,
                  reply.glossarySupported == self.model.supportsGlossary else {
                throw MiningError.message("The local speech runtime could not load \(self.model.name). See \(self.logURL.path).")
            }
        }
    }

    func transcribe(_ audio: [Float], language: GameLanguage, glossary: [String]) async throws -> [SpokenWord] {
        guard model.supports(language) else { throw MiningError.message("\(model.name) does not support word timings for \(language.name). Choose another transcription model.") }
        return try await operation(timeout: 60) {
            let data = audio.withUnsafeBytes { Data($0) }
            let request = Request(id: UUID().uuidString, audio: data.base64EncodedString(), language: language.rawValue,
                                  glossary: self.model.supportsGlossary ? glossary : [])
            var encoded = try JSONEncoder().encode(request)
            encoded.append(10)
            try self.input.fileHandleForWriting.write(contentsOf: encoded)
            let reply = try self.readReply()
            guard reply.id == request.id else { throw MiningError.message("The speech runtime returned an unexpected response. Reload the models.") }
            if let error = reply.error { throw MiningError.message(error) }
            guard let words = reply.words else { throw MiningError.message("The speech runtime returned no word timings.") }
            let duration = Double(audio.count) / 16000
            guard words.allSatisfy({ !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.001 }) else {
                throw MiningError.message("The speech runtime returned invalid word timings. See \(self.logURL.path).")
            }
            return words.map { SpokenWord(text: $0.text, start: $0.start, end: min(duration, $0.end)) }
        }
    }

    func shutdown() async {
        stop()
        await Task.detached { if self.process.isRunning { self.process.waitUntilExit() } }.value
    }

    private func operation<T: Sendable>(timeout: TimeInterval, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached { try self.perform(timeout: timeout, body) }.value
        } onCancel: { self.stop() }
    }

    private func perform<T>(timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        io.lock()
        defer { io.unlock() }
        let deadline = DispatchWorkItem { self.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        do { return try body() }
        catch { stop(); throw error }
    }

    private func launch() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !stopped else { throw CancellationError() }
        try process.run()
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }

    private func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) }
            }
        }
    }

    private func readReply() throws -> Reply {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                return try JSONDecoder().decode(Reply.self, from: line)
            }
            guard pending.count < 8 * 1024 * 1024 else {
                throw MiningError.message("The speech runtime response exceeded its size limit.")
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw MiningError.message("The local speech runtime stopped or timed out. Reload the models; see \(logURL.path).")
            }
            pending.append(chunk)
        }
    }
}
