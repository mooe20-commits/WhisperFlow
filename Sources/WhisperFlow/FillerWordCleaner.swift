import Foundation

/// Removes common spoken filler words from transcribed text.
/// Uses word-boundary matching to avoid false positives (e.g. "umbrella" ≠ "um").
final class FillerWordCleaner {

    // Fillers that should always be removed.
    // The regex treats multi-word phrases as units (anchored at start/end
    // of the phrase, not between every word), so multi-word fillers would
    // match as a phrase, not as words individually.
    //
    // SCOPE: only pure SOUND fillers. Meaningful spoken words and phrases
    // (you know, let me think, kind of, basically, etc.) are NOT stripped —
    // the user has decided to keep them in the output because they may
    // carry intent or cadence.
    private static let fillers: [String] = [
        // Single-word sounds — pure non-lexical vocalizations
        "uh", "um", "umm", "ummm", "ums", "uhs",
        "er", "ers",
        "ah", "ahs",
        "hmm", "hm", "hmmm", "hmmmm", "h",
        "mhm", "mm-hmm", "mm", "mmm",
        "uh-huh", "mm-hm", "uhm", "uhhh", "ahh", "ehh",
    ]

    // Aggressive fillers (leading/trailing sentence position).
    // Currently empty — the user has decided to preserve all leading
    // spoken words. Keep this group as a hook for future tuning.
    private static let leadingFillers: [String] = []

    private let mainPattern: NSRegularExpression
    private let leadingPattern: NSRegularExpression

    init() {
        // Build a phrase-aware pattern. The whole phrase is captured as one
        // group, anchored by word boundaries only at the start and end —
        // NOT between every internal word. This makes "you know" match as
        // a phrase instead of as "you" OR "know" individually.
        //
        // Phrases are sorted longest-first so that "let me think for a
        // second" matches before "let me think" (regex alternation is
        // left-to-right, longest-match-wins in our hand-built alternation).
        let sortedFillers = FillerWordCleaner.fillers.sorted { a, b in
            a.count > b.count
        }
        let mainEscaped = sortedFillers
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // (?<![\w']) and (?![\w']) are lookarounds that assert the
        // character before/after the phrase is NOT a word char or apostrophe.
        // This is more robust than \b for phrases containing internal
        // apostrophes like "I don't" or "y'know".
        let mainRegex = "(?<![\\w'])(?i)(\(mainEscaped))(?![\\w'])"

        // Leading pattern: matches fillers at start of sentence
        let leadingEscaped = FillerWordCleaner.leadingFillers
            .sorted { a, b in a.count > b.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let leadingRegex = "(?i)^(\(leadingEscaped)),?\\s+"

        self.mainPattern = try! NSRegularExpression(pattern: mainRegex)
        self.leadingPattern = try! NSRegularExpression(pattern: leadingRegex)
    }

    func clean(_ text: String) -> String {
        var result = text

        // Remove core fillers
        result = mainPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )

        // Remove leading fillers sentence by sentence
        let sentences = splitSentences(result)
        result = sentences.map { sentence in
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            return leadingPattern.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
        }.joined(separator: " ")

        // Collapse multiple spaces
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)

        // Clean up spaces before punctuation
        result = result.replacingOccurrences(of: "\\s+([.,;:!?])", with: "$1", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespaces)
    }

    private func splitSentences(_ text: String) -> [String] {
        // Simple split on sentence-ending punctuation followed by space
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if ".!?".contains(char) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current)
        }
        return sentences.isEmpty ? [text] : sentences
    }
}
