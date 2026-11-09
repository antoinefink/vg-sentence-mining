import Foundation

public struct SpeechDirectories: Equatable, Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VG Sentence Mining", isDirectory: true)
    }
    public let directory: URL
    public var modelsDirectory: URL { directory.appendingPathComponent("Models", isDirectory: true) }
    public var runtimeDirectory: URL { directory.appendingPathComponent("SpeechRuntime", isDirectory: true) }

    public init(directory: URL) {
        self.directory = URL(fileURLWithPath: directory.standardizedFileURL.path, isDirectory: true)
    }

    public static func load(defaults: UserDefaults = .standard, environment: [String: String] = [:]) -> Self {
        func directory(_ value: String?) -> URL? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Self(directory: directory(environment["VG_SPEECH_DIRECTORY"] ?? defaults.string(forKey: "speechDirectory")) ?? defaultDirectory)
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(directory.path, forKey: "speechDirectory")
    }
}
