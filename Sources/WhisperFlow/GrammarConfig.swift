import Foundation

/// Toggles the post-processing cleanup pass. Persisted in UserDefaults.
///
/// - `.autoPunctuate` (default): `GrammarCorrector` adds a trailing period
///   if the last char isn't `.!?`, and capitalizes sentence starts. Good
///   for prose / chat / email. Bad for code, terminal commands, or JSON
///   fields — you don't want `git status.` to come out of your mouth.
///
/// - `.raw` (opt-in): no capitalization, no terminal punctuation. The
///   user's punctuation is preserved verbatim. Use this for technical
///   dictation (commands, n8n nodes, code dictation, file paths).
enum GrammarMode: String, CaseIterable {
    case autoPunctuate
    case raw

    var displayName: String {
        switch self {
        case .autoPunctuate:
            return "Auto-punctuate  (capitalize + add . at end)"
        case .raw:
            return "Raw             (preserve your punctuation, no . appended)"
        }
    }

    var shortName: String {
        switch self {
        case .autoPunctuate: return "auto-punctuate"
        case .raw:           return "raw"
        }
    }

    /// Default for new installs — auto-punctuate is the friendlier
    /// out-of-the-box experience for prose. Users who dictate commands
    /// will switch to `.raw` via the menu.
    static let defaultMode: GrammarMode = .autoPunctuate
}

enum GrammarConfig {
    private static let key = "WFGrammarMode"

    static func current() -> GrammarMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = GrammarMode(rawValue: raw)
        else {
            return GrammarMode.defaultMode
        }
        return mode
    }

    @discardableResult
    static func set(_ mode: GrammarMode) -> Bool {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        return true
    }
}
