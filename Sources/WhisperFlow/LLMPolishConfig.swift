import Foundation

/// Opt-in LLM polish settings (Phase B of the Jot upgrade). Persisted in
/// UserDefaults, following the existing FillerConfig/GrammarConfig pattern.
///
/// - `isEnabled` (default **false**): with the toggle OFF, the pipeline
///   never consults this config beyond a single Bool check — behavior is
///   byte-identical to Phase A. No latency, no new calls.
/// - `model`: Ollama model id used for the cleanup call. Default is the
///   on-disk MiniCPM 2B id — nothing is downloaded, pulled, or loaded by
///   default; the operator must already have it (`ollama list`).
/// - `timeoutSeconds` (default 15): hard bound on the LLM call. On expiry
///   the Phase A result is used — the fallback is never blocked.
enum LLMPolishConfig {

    private static let enabledKey = "WFPolishLLMEnabled"
    private static let modelKey = "WFPolishLLMModel"
    private static let timeoutKey = "WFPolishLLMTimeout"

    /// On-disk MiniCPM 2B — verified present via `ollama list`, so enabling
    /// the toggle never triggers a download.
    static let defaultModel = "hf.co/Abiray/MiniCPM5-2B-heretic-abliterated-GGUF:Q4_K_M"
    static let defaultTimeout: TimeInterval = 15

    /// Single Bool read. This is the ONLY thing the toggle-off path calls.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        return true
    }

    static var model: String {
        let raw = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultModel : raw
    }

    @discardableResult
    static func setModel(_ id: String) -> Bool {
        UserDefaults.standard.set(id, forKey: modelKey)
        return true
    }

    static var timeoutSeconds: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: timeoutKey)
        // 0 means "never set" (UserDefaults returns 0 for missing keys) —
        // and a sub-second timeout is never useful. Clamp to [2, 120].
        guard raw >= 2 else { return defaultTimeout }
        return min(raw, 120)
    }

    @discardableResult
    static func setTimeout(_ seconds: TimeInterval) -> Bool {
        UserDefaults.standard.set(seconds, forKey: timeoutKey)
        return true
    }
}
