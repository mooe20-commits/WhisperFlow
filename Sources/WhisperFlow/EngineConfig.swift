import Foundation

/// Engine mode persisted in UserDefaults. Selected from the menu.
///
/// - `subprocess` (default): one-shot Python wrapper per transcription.
///   ~1.5s overhead per call, no idle memory cost.
/// - `daemon`: long-running Python daemon with the model resident in RAM.
///   ~50-100ms per call, 800MB-1.8GB idle cost.
enum TranscriptionEngine: String, CaseIterable {
    case subprocess
    case daemon

    var displayName: String {
        switch self {
        case .subprocess:
            return "subprocess  (~1.5–2s per call: model load dominates, 0 idle RAM)"
        case .daemon:
            return "daemon      (near-instant, ~1.5GB idle RAM)"
        }
    }

    var shortName: String {
        switch self {
        case .subprocess: return "subprocess"
        case .daemon:     return "daemon"
        }
    }

    /// Default engine when no UserDefault is set.
    /// v0.9.8: daemon is the default — 50–80ms transcription is a far better
    /// first experience than a 1.5–2.2s subprocess wait, and the daemon
    /// auto-starts/stops with the app so there's no manual management.
    static let defaultEngine: TranscriptionEngine = .daemon
}

/// Persists the user's engine choice. Defaults to daemon (fastest
/// experience; auto-starts with the app, RAM released on quit).
enum EngineConfig {
    private static let key = "WFTranscriptionEngine"

    static func current() -> TranscriptionEngine {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let engine = TranscriptionEngine(rawValue: raw)
        else {
            return TranscriptionEngine.defaultEngine
        }
        return engine
    }

    @discardableResult
    static func set(_ engine: TranscriptionEngine) -> Bool {
        UserDefaults.standard.set(engine.rawValue, forKey: key)
        return true
    }
}
