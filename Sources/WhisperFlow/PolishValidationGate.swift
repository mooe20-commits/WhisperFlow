import Foundation

// Phase A of the Jot upgrade: Swift port of Jot's ValidationGate.
// Original: JotCore/Sources/FormattingPipeline/ValidationGate.swift
// (Apache-2.0, google-gemini/jot-gemini-transcribe-macOS).
//
// The "never insert garbage" gate (<1ms, runs between polish and
// injection). Defends against prompted-cleanup failure modes (answering
// the dictation instead of cleaning it, paraphrase drift, hallucinated
// expansion, content-dropping). On rejection the caller falls back to
// the pre-polish transcript — which here already has filler removal and
// grammar applied, so it is a high-quality fallback.
//
// Pure logic, no dependencies. Tuned constants are deliberately
// generous: self-correction collapse legitimately halves a transcript;
// answer-mode diverges in *content*, which containment catches.
enum PolishValidationGate {

    struct Verdict: Equatable {
        let accepted: Bool
        let reason: String?
        static let ok = Verdict(accepted: true, reason: nil)
        static func fail(_ reason: String) -> Verdict { Verdict(accepted: false, reason: reason) }
    }

    // Tuned against Jot's live probe fixtures (see ValidationGateTests upstream).
    static let minLengthRatio = 0.20
    static let maxLengthRatio = 1.60
    static let minContainment = 0.50
    static let minTrigramSimilarity = 0.55

    /// Strips model artifacts that are not failures: code fences,
    /// "CLEAN:"/"Transcript:" labels, wrapping quotes.
    /// (Our deterministic pipeline rarely produces these, but the strip
    /// is cheap and keeps the gate faithful to the reference.)
    static func stripArtifacts(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "```", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["CLEAN:", "Clean:", "Transcript:", "TRANSCRIPT:"] where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.count > 1, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    static func validate(raw: String, cleaned: String) -> Verdict {
        let rawWords = contentWords(of: raw)
        let cleanWords = contentWords(of: cleaned)

        if cleanWords.isEmpty {
            return rawWords.isEmpty ? .ok : .fail("empty_output")
        }
        // Answer-preamble check: an answering model PREPENDS words that are
        // not in the dictation; a faithful cleanup preserves the speaker's
        // opener. So the pattern only fires when the cleaned text's first
        // word differs from the raw's first word — otherwise a dictation
        // that starts with "Okay," would be rejected for keeping its own
        // opener (first dogfood field bug upstream).
        if let answerPattern,
           answerPattern.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) != nil,
           cleanWords.first != rawWords.first {
            return .fail("answer_pattern")
        }
        if cleaned.range(of: "as an ai", options: .caseInsensitive) != nil
            || cleaned.range(of: "language model", options: .caseInsensitive) != nil {
            return .fail("ai_selfreference")
        }
        guard !rawWords.isEmpty else { return .ok }

        let ratio = Double(cleanWords.count) / Double(rawWords.count)
        // Expansion is most dangerous on short raws (hallucinated content),
        // so the upper bound kicks in early; shrink is legitimate
        // (filler/self-correction collapse), so the lower bound only
        // applies to longer raws.
        if rawWords.count >= 3, ratio > maxLengthRatio {
            return .fail("expansion_ratio_\(String(format: "%.2f", ratio))")
        }
        if rawWords.count >= 6, ratio < minLengthRatio {
            return .fail("shrink_ratio_\(String(format: "%.2f", ratio))")
        }

        let rawSet = Set(rawWords)
        let contained = cleanWords.filter { rawSet.contains($0) }.count
        let containment = Double(contained) / Double(cleanWords.count)
        let trigram = trigramSimilarity(normalize(raw), normalize(cleaned))
        // Reject only when BOTH content signals diverge — cleanup
        // legitimately rewrites number words and punctuation words,
        // hurting each individually.
        if containment < minContainment && trigram < minTrigramSimilarity {
            return .fail("content_divergence_c\(String(format: "%.2f", containment))_t\(String(format: "%.2f", trigram))")
        }
        return .ok
    }

    // MARK: - Text plumbing

    /// N3-style: optional, never `try!`. A bad pattern disables only the
    /// answer-preamble check instead of crashing the app at launch.
    private static let answerPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(sure|okay|certainly|of course|great question|here('s| is)|i can('t|not)|as an ai|i'm (sorry|an ai))\b"#,
        options: [.caseInsensitive]
    )

    /// Lowercased alphanumeric words with spoken numbers normalized to
    /// digits so "three" (raw) matches "3" (polished output).
    static func contentWords(of text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        for (word, digit) in numberWords {
            s = s.replacingOccurrences(of: "\\b\(word)\\b", with: digit, options: .regularExpression)
        }
        return s
    }

    private static let numberWords: [(String, String)] = [
        ("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"),
        ("five", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"), ("nine", "9"),
        ("ten", "10"), ("eleven", "11"), ("twelve", "12"), ("twenty", "20"),
        ("thirty", "30"), ("forty", "40"), ("fifty", "50"), ("hundred", "100"),
    ]

    static func trigramSimilarity(_ a: String, _ b: String) -> Double {
        let ta = trigrams(a), tb = trigrams(b)
        guard !ta.isEmpty, !tb.isEmpty else { return a == b ? 1 : 0 }
        let intersection = ta.intersection(tb).count
        return Double(intersection) / Double(min(ta.count, tb.count))
    }

    private static func trigrams(_ s: String) -> Set<String> {
        let chars = Array(s.filter { !$0.isWhitespace })
        guard chars.count >= 3 else { return chars.isEmpty ? [] : [String(chars)] }
        var set = Set<String>()
        for i in 0...(chars.count - 3) {
            set.insert(String(chars[i...(i + 2)]))
        }
        return set
    }
}
