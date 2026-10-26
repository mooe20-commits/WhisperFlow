import Foundation

/// User dictionary: wrong→right word map applied as a deterministic
/// post-pass with word boundaries (Phase A of the Jot upgrade — mirrors
/// Jot's ReplacementEngine guarantee: the dictionary *enforces* explicit
/// rules instead of suggesting them).
///
/// Persisted in UserDefaults as JSON, following the existing
/// FillerConfig/GrammarConfig pattern. Editable at runtime via
/// add/remove/setEntries — no app restart needed.
///
/// Seed entries are the owner's crypto capitalizations, using the forms
/// Whisper actually emits (split compounds like "thor chain"):
///   "thor chain"  → "THORChain"
///   "hyper liquid" → "Hyperliquid"
///   "rune"        → "RUNE"
///
/// Tradeoff: "rune"→"RUNE" also uppercases the English word "rune"
/// (ancient alphabet). Correct for this owner's dictation; remove the
/// entry with `DictionaryConfig.remove("rune")` if that ever matters.
enum DictionaryConfig {

    private static let key = "WFUserDictionary"

    /// Seed map for new installs. The canonical `right` casing is always
    /// substituted as-authored (no case propagation — every entry here
    /// carries explicit casing: RUNE, THORChain, Hyperliquid).
    static let seedEntries: [String: String] = [
        "thor chain": "THORChain",
        "hyper liquid": "Hyperliquid",
        "rune": "RUNE",
    ]

    /// Current map. Falls back to the seeds on first launch (or if the
    /// stored JSON is corrupt — corrupt data disables custom entries,
    /// never the pipeline).
    static func entries() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return seedEntries
        }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return seedEntries
        }
        return decoded
    }

    @discardableResult
    static func setEntries(_ map: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(map) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    @discardableResult
    static func add(wrong: String, right: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return false }
        var map = entries()
        // Case-insensitive keying: "Rune" and "rune" are the same entry.
        map.removeValue(forKey: map.keys.first(where: { $0.lowercased() == w.lowercased() }) ?? w)
        map[w] = r
        return setEntries(map)
    }

    @discardableResult
    static func remove(_ wrong: String) -> Bool {
        var map = entries()
        guard let existing = map.keys.first(where: { $0.lowercased() == wrong.lowercased() }) else {
            return false
        }
        map.removeValue(forKey: existing)
        return setEntries(map)
    }

    @discardableResult
    static func resetToSeeds() -> Bool {
        setEntries(seedEntries)
    }

    // MARK: - Post-pass

    /// Applies the map longest-match-first, case-insensitive, with word
    /// boundaries. Lookarounds (instead of `\b`) so wrong-forms starting
    /// or ending in punctuation still match. A bad pattern for one entry
    /// skips that entry instead of aborting the pass.
    static func apply(to text: String) -> String {
        let rules = entries()
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for wrong in rules.keys.sorted(by: { $0.count > $1.count }) {
            guard let right = rules[wrong], !wrong.isEmpty else { continue }
            let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: wrong))(?![\\w])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: right)
            }
        }
        return result
    }
}
