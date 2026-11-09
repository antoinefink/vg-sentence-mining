import CryptoKit
import Darwin
import Foundation
import MiningCore

public struct SpeechInstallProgress: Sendable, Decodable {
    public var message: String
    public var completed: Int64?
    public var total: Int64?

    public init(message: String, completed: Int64? = nil, total: Int64? = nil) {
        self.message = message; self.completed = completed; self.total = total
    }

    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public enum SpeechInstallation {
    public static func python(runtime: URL, model: TranscriptionModel) -> URL {
        let isolated = runtime.appendingPathComponent("Environments/\(model.rawValue)/.venv/bin/python")
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let environments = manifest["environments"] as? [String: String],
           environments[model.rawValue] == "Environments/\(model.rawValue)/.venv/bin/python" { return isolated }
        return runtime.appendingPathComponent(".venv/bin/python")
    }

    public static func isInstalled(_ model: TranscriptionModel, in directories: SpeechDirectories) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python(runtime: directories.runtimeDirectory, model: model).path),
              let data = try? Data(contentsOf: directories.runtimeDirectory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["protocol"] as? Int == 1,
              let models = manifest["models"] as? [String: [String: String]] else { return false }
        let required = model == .qwen3ASR ? [model.rawValue, "qwen3-aligner"] : [model.rawValue]
        return required.allSatisfy { name in
            guard let metadata = models[name], let stored = metadata["path"], let revision = metadata["revision"] else { return false }
            // Retain support for installations made before relative manifests.
            let relative = stored.hasPrefix("/")
                ? name + "/" + revision + (name == "parakeet-ultra" ? "/" + URL(fileURLWithPath: stored).lastPathComponent : "")
                : stored
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return false }
            return FileManager.default.fileExists(atPath: directories.modelsDirectory.appendingPathComponent(relative).path)
        }
    }
}

/// Installs only the requested model. Runtime packages and model revisions are pinned.
public final class SpeechModelInstaller: Sendable {
    private let runner = InstallProcess()
    private static let uvVersion = "0.13.7"
    private static let uvHash = "81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731"

    public init() {}

    public func install(_ model: TranscriptionModel, in directories: SpeechDirectories,
                        progress: @escaping @Sendable (SpeechInstallProgress) -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let fm = FileManager.default
            let runtime = directories.runtimeDirectory
            try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
            let lock = open(runtime.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0 else { throw MiningError.message("The speech folder is not writable. Choose another folder in Settings.") }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                throw MiningError.message("Another speech installation is in progress. Wait for it to finish, then retry.")
            }
            defer { flock(lock, LOCK_UN) }
            let space = try runtime.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            let needed: Int64 = model == .qwen3ASR ? 12_000_000_000 : model == .whisperLargeV3 ? 7_000_000_000 : 3_000_000_000
            if let space, space < needed {
                throw MiningError.message("Free at least \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) on this disk, or choose another speech folder.")
            }
            let logs = runtime.appendingPathComponent("Logs")
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent("installation.log")
            try Data().write(to: log, options: .atomic)
            progress(.init(message: "Preparing the speech engine…"))
            let uv = try await bootstrap(runtime: runtime, log: log)
            var environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("UV_") && !$0.key.hasPrefix("PIP_") && !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("HF_")
            }
            environment["UV_PYTHON_INSTALL_DIR"] = runtime.appendingPathComponent("Python").path
            environment["UV_CACHE_DIR"] = runtime.appendingPathComponent("cache/uv").path
            environment["UV_PYTHON_PREFERENCE"] = "only-managed"
            environment["UV_NO_PROGRESS"] = "1"
            environment["UV_PYTHON_INSTALL_BIN"] = "0"
            let venv = runtime.appendingPathComponent("Environments/\(model.rawValue)/.venv")
            if !fm.isExecutableFile(atPath: venv.appendingPathComponent("bin/python").path) {
                try await runner.run(uv, ["--no-config", "venv", "--python", "3.12.11", "--relocatable", venv.path], environment: environment, log: log)
            }
            guard let requirements = Bundle.module.url(forResource: model.rawValue, withExtension: "txt", subdirectory: "Requirements"),
                  let script = Bundle.module.url(forResource: "install_model", withExtension: "py") else {
                throw MiningError.message("The app is missing its installer files. Reinstall VG Sentence Mining.")
            }
            progress(.init(message: "Installing the \(model.name) engine…"))
            let python = venv.appendingPathComponent("bin/python")
            try await runner.run(uv, ["--no-config", "pip", "install", "--python", python.path,
                                      "--only-binary", ":all:", "--require-hashes", "--index-url", "https://pypi.org/simple",
                                      "--requirements", requirements.path], environment: environment, log: log)
            progress(.init(message: "Connecting to the model download…"))
            try await runner.run(python, ["-u", script.path, "--destination", directories.directory.path, "--model", model.rawValue],
                                 environment: environment, log: log, progress: progress)
            try Task.checkCancellation()
            guard SpeechInstallation.isInstalled(model, in: directories) else {
                throw MiningError.message("The installation is incomplete. Retry to finish the download.")
            }
        } onCancel: { self.runner.cancel() }
    }

    private func bootstrap(runtime: URL, log: URL) async throws -> URL {
        let root = runtime.appendingPathComponent("Bootstrap/uv-\(Self.uvVersion)")
        let executable = root.appendingPathComponent("uv-aarch64-apple-darwin/uv")
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        let staging = runtime.appendingPathComponent("Bootstrap/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let url = URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-aarch64-apple-darwin.tar.gz")!
        let (download, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              SHA256.hash(data: try Data(contentsOf: download)).map({ String(format: "%02x", $0) }).joined() == Self.uvHash else {
            throw MiningError.message("The speech-engine download could not be verified. Check your connection and retry.")
        }
        try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", download.path, "-C", staging.path], environment: nil, log: log)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.moveItem(at: staging, to: root)
        return executable
    }
}

final class InstallProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, log: URL,
             progress: @escaping @Sendable (SpeechInstallProgress) -> Void = { _ in }) async throws {
        try await Task.detached { try self.perform(executable, arguments, environment: environment, log: log, progress: progress) }.value
    }

    private func perform(_ executable: URL, _ arguments: [String], environment: [String: String]?, log: URL,
                         progress: @escaping @Sendable (SpeechInstallProgress) -> Void) throws {
        let process = Process(), output = Pipe()
        let diagnostics = try FileHandle(forWritingTo: log)
        defer { try? diagnostics.close() }
        try diagnostics.seekToEnd()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment
        process.standardOutput = output; process.standardError = diagnostics
        self.lock.lock()
        if self.cancelled { self.lock.unlock(); throw CancellationError() }
        self.process = process
        do { try process.run() } catch { self.process = nil; self.lock.unlock(); throw error }
        self.lock.unlock()
        try? output.fileHandleForWriting.close()
        var pending = Data()
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]
                if let update = try? JSONDecoder().decode(SpeechInstallProgress.self, from: line) { progress(update) }
                pending.removeSubrange(...end)
            }
            if pending.count > 64 * 1024 { pending.removeAll() }
        }
        process.waitUntilExit()
        self.lock.lock(); let cancelled = self.cancelled; self.process = nil; self.lock.unlock()
        if cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw MiningError.message("Installation stopped. Check your internet connection and free disk space, then retry. Details are in SpeechRuntime/Logs/installation.log.")
        }
    }
}
