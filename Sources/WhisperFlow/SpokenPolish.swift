import Foundation

/// Deterministic spoken-form polish (Phase A of the Jot upgrade):
/// converts dictated punctuation cues and number words to written form.
///
/// SCOPE — only what FillerWordCleaner and GrammarCorrector do NOT cover:
/// - FillerWordCleaner: filler removal + space-before-punctuation tidy.
/// - GrammarCorrector: sentence capitalization + terminal punctuation.
/// - This pass: "new line"/"new paragraph" breaks, spoken punctuation
///   cues (comma, period/full stop, question mark, exclamation mark),
///   and number words → digits (Jot PromptV1 rules: "Convert spoken
///   punctuation when clearly commands" and "Use digits for numbers").
///
/// Deterministic heuristics, so false positives are possible where the
/// cue is meant literally ("the Jurassic period"). Two guards limit the
/// damage: a cue preceded by a determiner ("a comma", "the period") is
/// treated as a literal noun and left alone, and a lone "one" is never
/// converted (pronoun risk: "one of us"). The ValidationGate downstream
/// is the backstop against garbage, not against these judgment calls.
enum SpokenPolish {

    static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = joinHyphenatedNumbers(text)
        s = convertNumberRuns(s)
        s = convertBreakCues(s)
        s = convertInlinePunctuation(s)
        s = convertTrailingCues(s)
        s = capitalizeAfterSentencePunctuation(s)
        // Tidy: collapse 3+ spaces (FillerWordCleaner handles 2+, but our
        // insertions can create new runs) without touching newlines.
        s = s.replacingOccurrences(of: " {3,}", with: " ", options: .regularExpression)
        // Break cues replace from the cue word onward, leaving the space
        // before it: "item new line next" → "item \nnext". Fix that here.
        s = s.replacingOccurrences(of: " +\n", with: "\n", options: .regularExpression)
        // Newlines from break cues: never more than a paragraph gap.
        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Break cues ("new line" / "new paragraph")

    private static func convertBreakCues(_ text: String) -> String {
        var s = text
        // Paragraph first (it contains "new p…", no overlap with "new line",
        // but longest-first is the safe habit).
        s = replaceGuarded(s, cuePattern: "new\\s+paragraph", replacement: "\n\n")
        s = replaceGuarded(s, cuePattern: "new\\s+line", replacement: "\n")
        return s
    }

    /// Replaces a cue phrase anywhere, unless the word before it is a
    /// determiner ("a new line of thinking" stays literal).
    private static func replaceGuarded(_ text: String, cuePattern: String, replacement: String) -> String {
        // Negative lookbehind needs fixed width: enumerate determiners.
        // Trailing whitespace after the cue is consumed so "item new line
        // next" becomes "item\nnext", not "item\n next".
        let dets = determiners.joined(separator: "|")
        let pattern = "(?i)(?<![\\w])(?<!\\b(?:\(dets))\\s)(?:\(cuePattern))(?![\\w])\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private static let determiners = [
        "a", "an", "the", "this", "that", "these", "those",
        "no", "any", "each", "every", "some",
        "my", "his", "her", "its", "our", "their", "your",
    ]

    // MARK: - Inline punctuation cues ("say hello comma how are you")

    private static func convertInlinePunctuation(_ text: String) -> String {
        var s = text
        // Comma between words: "hello comma world" → "hello, world".
        s = replaceInlineCue(s, cuePattern: "comma", punctuation: ",")
        // Period between words: "first period second" → "first. Second".
        // "full stop" variant included (British dictation).
        s = replaceInlineCue(s, cuePattern: "period|full\\s+stop", punctuation: ".")
        s = replaceInlineCue(s, cuePattern: "question\\s+mark", punctuation: "?")
        s = replaceInlineCue(s, cuePattern: "exclamation\\s+(?:mark|point)", punctuation: "!")
        return s
    }

    /// `left CUE right` → `left< punct> right`, only when both sides have
    /// word characters (so trailing cues are left for convertTrailingCues)
    /// and the left word is not a determiner ("use a comma here" stays
    /// literal — checked per-match, since a lookbehind at match start
    /// would test the word *before* the cue's neighbor, not the neighbor).
    private static func replaceInlineCue(_ text: String, cuePattern: String, punctuation: String) -> String {
        let pattern = "(?i)([\\w'\\)\\\"]+)\\s+(?:\(cuePattern))\\s+(?=[\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let leftRange = Range(match.range(at: 1), in: text),
                  let wholeRange = Range(match.range, in: text)
            else { continue }
            // The match consumes the gap after the cue; keep one space.
            if determiners.contains(String(text[leftRange]).lowercased()) { continue }
            out += text[cursor..<wholeRange.lowerBound]
            out += "\(text[leftRange])\(punctuation) "
            cursor = wholeRange.upperBound
        }
        out += text[cursor...]
        return out
    }

    // MARK: - Trailing cues ("…question mark" at the end)

    private static func convertTrailingCues(_ text: String) -> String {
        var s = text
        // GrammarCorrector may already have appended "." after the cue
        // ("hello period" → "Hello period."), so allow an optional dot.
        s = replaceTrailingCue(s, cuePattern: "question\\s+mark", punctuation: "?")
        s = replaceTrailingCue(s, cuePattern: "exclamation\\s+(?:mark|point)", punctuation: "!")
        s = replaceTrailingCue(s, cuePattern: "period|full\\s+stop", punctuation: ".")
        // Trailing "comma" is a dictated pause, not punctuation — drop it.
        if let regex = try? NSRegularExpression(pattern: "(?i)\\s*\\bcomma\\.?\\s*$") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s
    }

    private static func replaceTrailingCue(_ text: String, cuePattern: String, punctuation: String) -> String {
        let dets = determiners.joined(separator: "|")
        // Literal-noun check first: "the period" / "a question mark" at the
        // end is a noun phrase, not a command — leave the text alone.
        if (try? NSRegularExpression(pattern: "(?i)\\b(?:\(dets))\\s+(?:\(cuePattern))\\.?\\s*$"))
            .flatMap({ $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) }) != nil {
            return text
        }
        // Consume the space before the cue so "standup question mark"
        // becomes "standup?", not "standup ?".
        let pattern = "(?i)\\s*(?:\(cuePattern))\\.?\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let replaced = regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: punctuation)
        // If the cue followed terminal punctuation already ("…mark." →
        // "…?"), collapse "?."-style doubles.
        return replaced
            .replacingOccurrences(of: "?.", with: "?")
            .replacingOccurrences(of: "!.", with: "!")
            .replacingOccurrences(of: "..", with: ".")
    }

    // MARK: - Capitalization after inserted punctuation

    /// GrammarCorrector already ran, so only fix up letters following
    /// punctuation WE inserted (inline cues leave the follower lowercase).
    private static func capitalizeAfterSentencePunctuation(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([.!?\\n]\\s*)([a-z])") else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        var s = text
        for match in matches {
            guard match.numberOfRanges == 3,
                  let r2 = Range(match.range(at: 2), in: s) else { continue }
            s.replaceSubrange(r2, with: String(s[r2]).uppercased())
        }
        return s
    }

    // MARK: - Number words → digits

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static func isNumberWord(_ w: String) -> Bool {
        let l = w.lowercased()
        return units[l] != nil || tens[l] != nil || scales[l] != nil
    }

    /// "twenty-three" → "twenty three" so the run parser sees it.
    /// Only between two number words — "well-known" is untouched.
    private static func joinHyphenatedNumbers(_ text: String) -> String {
        let words = Array(Set(units.keys).union(tens.keys).union(scales.keys)).joined(separator: "|")
        let pattern = "(?i)\\b(\(words))-(?=\(words)\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1 ")
    }

    /// Finds maximal runs of number words and renders each as digits.
    /// - Lone scale words ("a hundred") stay literal.
    /// - A lone "one" stays literal (pronoun risk: "one of us").
    /// - Runs without scales combine tens+unit pairs ("twenty three"→23,
    ///   "twenty twenty six"→2026, "one two three"→123).
    /// - Runs with scales use chunk parsing ("one hundred five"→105).
    private static func convertNumberRuns(_ text: String) -> String {
        // Tokenize into words, group consecutive number words separated
        // only by spaces, then rebuild in one forward pass (avoids
        // index-shift bugs from in-place replacement).
        guard let wordRegex = try? NSRegularExpression(pattern: "[A-Za-z]+") else { return text }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = wordRegex.matches(in: text, range: fullRange)
        func word(_ i: Int) -> String {
            String(text[Range(matches[i].range, in: text)!])
        }
        // Maximal runs of adjacent number words (gap must be spaces only).
        var runs: [(Int, Int)] = []
        var runStart: Int? = nil
        for i in 0..<matches.count {
            if isNumberWord(word(i)) {
                if runStart == nil {
                    runStart = i
                } else {
                    let prevEnd = Range(matches[i - 1].range, in: text)!.upperBound
                    let thisStart = Range(matches[i].range, in: text)!.lowerBound
                    if text[prevEnd..<thisStart].rangeOfCharacter(from: CharacterSet.whitespaces.inverted) != nil {
                        runs.append((runStart!, i - 1))
                        runStart = i
                    }
                }
            } else if let rs = runStart {
                runs.append((rs, i - 1))
                runStart = nil
            }
        }
        if let rs = runStart {
            runs.append((rs, matches.count - 1))
        }
        // Render each run; nil means "leave literal".
        var spans: [(Range<String.Index>, String)] = []
        for (a, b) in runs {
            let words = (a...b).map { word($0) }
            guard let digits = renderNumberRun(words),
                  let sIdx = Range(matches[a].range, in: text)?.lowerBound,
                  let eIdx = Range(matches[b].range, in: text)?.upperBound
            else { continue }
            spans.append((sIdx..<eIdx, digits))
        }
        guard !spans.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for span in spans {
            out += text[cursor..<span.0.lowerBound]
            out += span.1
            cursor = span.0.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// Returns the digit string for a run of number words, or nil to leave
    /// the run literal (lone "one", lone scale word).
    private static func renderNumberRun(_ words: [String]) -> String? {
        let lower = words.map { $0.lowercased() }
        if lower.count == 1 {
            if lower[0] == "one" { return nil }
            if scales[lower[0]] != nil { return nil }
            if let v = units[lower[0]] ?? tens[lower[0]] { return String(v) }
            return nil
        }
        if lower.contains(where: { scales[$0] != nil }) {
            return renderScaledRun(lower)
        }
        // No scales: combine tens+unit pairs greedily left to right.
        var parts: [String] = []
        var i = 0
        while i < lower.count {
            if i + 1 < lower.count,
               let t = tens[lower[i]],
               let u = units[lower[i + 1]], u < 10 {
                parts.append(String(t + u))
                i += 2
            } else if let v = units[lower[i]] ?? tens[lower[i]] {
                parts.append(String(v))
                i += 1
            } else {
                return nil
            }
        }
        return parts.joined()
    }

    /// "one hundred five"→105, "two thousand twenty six"→2026.
    private static func renderScaledRun(_ lower: [String]) -> String? {
        var total = 0
        var current = 0
        for w in lower {
            if let v = units[w] ?? tens[w] {
                current += v
            } else if let scale = scales[w] {
                if current == 0 { return nil } // "hundred dollars" — literal
                current *= scale
                if scale >= 1_000 {
                    total += current
                    current = 0
                }
            } else {
                return nil
            }
        }
        return String(total + current)
    }
}
