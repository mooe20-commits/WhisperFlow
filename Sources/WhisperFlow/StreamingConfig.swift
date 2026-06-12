import Foundation

/// Controls the streaming partials behavior during active dictation.
///
/// Persisted in UserDefaults.
///
/// - `fast` (0.8s): most "live" feel, choppier updates. Good if you speak
///   in short bursts and want near-real-time feedback.
///
/// - `balanced` (1.0s, default): best balance — ~6 partials for a 6s
///   utterance, imperceptible latency, no mid-syllable fragmentation.
///
/// - `slow` (1.5s): more deliberate, fewer AX writes per recording.
///   Feels sluggish for fast speakers; useful if CPU is constrained.
enum CadenceMode: String, CaseIterable {
    case fast     = "fast"
    case balanced = "balanced"
    case slow     = "slow"

    var displayName: String {
        switch self {
        case .fast:     return "Fast     (0.8s, choppy)"
        case .balanced: return "Balanced (1.0s, recommended)"
        case .slow:     return "Slow     (1.5s, fewer updates)"
        }
    }

    /// Seconds between partial flushes during active capture.
    var seconds: TimeInterval {
        switch self {
        case .fast:     return 0.8
        case .balanced: return 1.0
        case .slow:     return 1.5
        }
    }

    static let defaultMode: CadenceMode = .balanced
}

// MARK: - Config

enum StreamingConfig {
    private static let cadenceKey    = "WFStreamingCadence"
    private static let partialKey   = "WFStreamingPartialEnabled"

    /// Current cadence mode.
    static func currentCadence() -> CadenceMode {
        guard let raw = UserDefaults.standard.string(forKey: cadenceKey),
              let mode = CadenceMode(rawValue: raw)
        else {
            return CadenceMode.defaultMode
        }
        return mode
    }

    @discardableResult
    static func setCadence(_ mode: CadenceMode) -> Bool {
        UserDefaults.standard.set(mode.rawValue, forKey: cadenceKey)
        return true
    }

    /// Whether partial in-place display is enabled.
    /// When disabled, no AX partial injection happens during capture —
    /// only the final pasteboard+Cmd+V fires on commit.
    static func currentPartialEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: partialKey) == nil {
            return true  // default: on
        }
        return UserDefaults.standard.bool(forKey: partialKey)
    }

    @discardableResult
    static func setPartialEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: partialKey)
        return true
    }
}
