import Foundation

public enum TranscriptionModel: String, CaseIterable, Codable, Sendable {
    case parakeetUltra = "parakeet-ultra"
    case whisperLargeV3 = "whisper-large-v3"
    case qwen3ASR = "qwen3-asr-1.7b"

    public var name: String {
        switch self {
        case .parakeetUltra: "Parakeet Ultra"
        case .whisperLargeV3: "Whisper Large V3"
        case .qwen3ASR: "Qwen3-ASR 1.7B"
        }
    }

    public var detail: String {
        switch self {
        case .parakeetUltra: "Fastest in our German tests. Does not use glossary hints."
        case .whisperLargeV3: "Supports glossary hints. Uses more processing time than Ultra."
        case .qwen3ASR: "Experimental. Supports glossary hints; word timing and recognition during background audio can be less reliable."
        }
    }

    public var supportsGlossary: Bool { self != .parakeetUltra }
    public var isExperimental: Bool { self == .qwen3ASR }
}
