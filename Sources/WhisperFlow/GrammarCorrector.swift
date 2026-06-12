import Foundation

/// Light grammar/cleanup pass: optional capitalisation + terminal punctuation.
///
/// v0.8: mode-driven. The previous version always added a trailing period
/// if the last char wasn't `.!?`, which is wrong for code, terminal
/// commands, and JSON fields — you don't want `git status.` to come out
/// of your mouth. The user can now pick:
///
/// - `.autoPunctuate` (default): capitalize sentence starts + append `.`
///   if missing. Good for prose / chat / email.
/// - `.raw`: no capitalization, no terminal punctuation. Preserve the
///   user's spoken output verbatim. Use this for technical dictation
///   (commands, n8n nodes, code dictation, file paths).
///
/// macOS does NOT expose a public grammar-correction API. NSSpellChecker
/// only does spelling, and its `correction(forWordRange:)` returns the
/// user's LEARNED correction (not a heuristic), so it does nothing useful
/// on a clean install. For real grammar correction you'd need a local
/// LanguageTool server (Java, ~300MB).
final class GrammarCorrector {

    /// The mode is read on every `correct()` call so the user can flip
    /// the menu item mid-session and the next transcription honors it
    /// without an app restart.
    private var mode: GrammarMode { GrammarConfig.current() }

    func correct(_ text: String) -> String {
        switch mode {
        case .autoPunctuate:
            return autoPunctuate(text)
        case .raw:
            // Pass-through. Trim only — the user owns punctuation.
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Auto-punctuate

    private func autoPunctuate(_ text: String) -> String {
        var result = text
        result = capitalizeSentences(result)
        result = ensureTerminalPunctuation(result)
        return result
    }

    private func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = ""
        var capitalizeNext = true

        for char in text {
            if capitalizeNext && char.isLetter {
                result.append(contentsOf: String(char).uppercased())
                capitalizeNext = false
            } else {
                result.append(char)
                // After sentence-ending punctuation, capitalize the next letter.
                if ".!?".contains(char) {
                    capitalizeNext = true
                }
            }
        }

        return result
    }

    private func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // FIX-8: Don't append a period if the text ends with a question mark —
        // the user likely asked a question and a trailing period is wrong.
        // Also skip if it already ends with . ! or ? (already punctuated).
        let lastChar = trimmed.last!
        if ".!?".contains(lastChar) {
            return trimmed
        }

        // Heuristic: if the text starts with a question word (what, when, where,
        // who, why, how, which, can, could, would, will, do, does, did, is, are,
        // was, were, should, would, shall — common spoken questions), don't add
        // a period. This avoids "What time is it." for a question. For more complex
        // sentences or multiple clauses, the heuristic may miss, but the user
        // can use .raw mode to disable all auto-punctuation.
        let leadingWords = trimmed.prefix(20).lowercased()
        let questionPrefixes = ["what", "when", "where", "who", "why", "how",
                               "which", "can ", "could", "would", "will ",
                               "do ", "does", "did ", "is ", "are ",
                               "was ", "were ", "should", "shall", "has ",
                               "have ", "had "]
        for prefix in questionPrefixes {
            if leadingWords.hasPrefix(prefix) {
                return trimmed  // question detected — no period
            }
        }

        return trimmed + "."
    }
}
