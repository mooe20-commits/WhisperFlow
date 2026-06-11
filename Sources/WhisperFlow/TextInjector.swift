import AppKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.whisperflow", category: "TextInjector")

/// Injects text at the active cursor position in any app.
///
/// Strategy: Pasteboard swap + Cmd+V is the ONLY reliable way to inject Unicode
/// (including Polish diacritics) across macOS apps. CGEvent keyboardSetUnicodeString
/// works for ASCII but silently drops accented characters in many apps.
///
/// We also inject a leading non-breaking space if needed to trigger auto-capitalize
/// heuristics in apps like Slack/Notes (avoid making the first letter lowercase
/// after our text lands in the middle of a sentence).
final class TextInjector {

    /// Inject text at the current cursor position.
    /// - Parameter restorePasteboard: if true, restore previous pasteboard contents
    ///   ~500ms after paste. Set false if the user has sensitive clipboard data
    ///   and we shouldn't touch it.
    func inject(_ text: String, restorePasteboard: Bool = true) {
        // Use the silent variant that re-evaluates TCC rather than the cached
        // process-level state. On Sequoia with ad-hoc signing, the bare
        // AXIsProcessTrusted() caches the pre-grant deny state in the running
        // process and returns false even when Accessibility is visibly granted.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        let axReady = AXIsProcessTrustedWithOptions(options)
        guard axReady else {
            logger.error("Accessibility not granted — cannot inject text (AXIsProcessTrustedWithOptions returned false)")
            return
        }

        injectViaPasteboard(text, restoreAfter: restorePasteboard)
    }

    // MARK: - Pasteboard + Cmd+V

    private func injectViaPasteboard(_ text: String, restoreAfter: Bool) {
        logger.info("Injecting via pasteboard: \(text.count) chars")

        let pasteboard = NSPasteboard.general
        let savedContents = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        // Write our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Tiny delay so the pasteboard swap is observable by the destination app
        usleep(20_000) // 20ms

        // Simulate Cmd+V
        postKeyCombo(keyCode: 0x09, flags: .maskCommand) // V

        // Restore original pasteboard content (best-effort)
        guard restoreAfter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Only restore if WE were the last writer — don't clobber a paste
            // the user made in the last 500ms.
            if pasteboard.changeCount == savedChangeCount + 1 {
                if let saved = savedContents {
                    pasteboard.clearContents()
                    pasteboard.setString(saved, forType: .string)
                } else {
                    pasteboard.clearContents()
                }
            }
        }
    }

    private func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
