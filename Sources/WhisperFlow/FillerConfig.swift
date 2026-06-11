import Foundation

/// Toggles the filler-word cleanup pass. Persisted in UserDefaults.
///
/// - `.standard` (default): removes spoken fillers (uh, um, like, I think,
///   you know, etc.) from transcribed text. Good for clean prose output.
///
/// - `.disabled`: no filler removal — filler words are preserved verbatim.
///   Use this when dictating prose where fillers carry intent or cadence,
///   or when the keep-list is causing false positives in technical content.
enum FillerMode: String, CaseIterable {
    case standard
    case disabled

    var displayName: String {
        switch self {
        case .standard:
            return "Standard  (remove uh, um, like, etc.)"
        case .disabled:
            return "Disabled  (keep all filler words)"
        }
    }

    var shortName: String {
        switch self {
        case .standard: return "standard"
        case .disabled: return "disabled"
        }
    }

    /// Default for new installs — standard cleanup is the right out-of-box
    /// experience for the typical command/code dictation use case.
    static let defaultMode: FillerMode = .standard
}

enum FillerConfig {
    private static let key = "WFFillerMode"

    static func current() -> FillerMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = FillerMode(rawValue: raw)
        else {
            return FillerMode.defaultMode
        }
        return mode
    }

    @discardableResult
    static func set(_ mode: FillerMode) -> Bool {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        return true
    }
}
