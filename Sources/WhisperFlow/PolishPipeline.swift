import Foundation

/// Phase A pipeline (Jot upgrade): deterministic polish + gate.
///
/// Order: existing cleaners (filler → grammar, run by the caller) →
/// user dictionary → regex polish → ValidationGate.
///
/// Gate rejection falls back to the pre-polish transcript (the caller's
/// filler+grammar output) — never empty, never garbage. A polished
/// result that strips to empty also falls back.
enum PolishPipeline {

    /// Returns the text to inject plus the gate verdict (for logging).
    /// `raw` is the untouched transcript; `base` is the output of the
    /// existing filler+grammar cleaners.
    static func finalize(raw: String, base: String) -> (text: String, verdict: PolishValidationGate.Verdict) {
        let prePolish = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prePolish.isEmpty else {
            return (prePolish, .ok)
        }
        var polished = DictionaryConfig.apply(to: prePolish)
        polished = SpokenPolish.apply(to: polished)
        polished = PolishValidationGate.stripArtifacts(polished)
        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Polish erased everything — fall back, don't insert empty.
            return (prePolish, .fail("polish_emptied"))
        }
        let verdict = PolishValidationGate.validate(raw: raw, cleaned: trimmed)
        guard verdict.accepted else {
            return (prePolish, verdict)
        }
        return (trimmed, verdict)
    }
}
