import AppKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.whisperflow", category: "TextInjector")

/// Injects text at the active cursor position in any app.
///
/// Two strategies, picked per call site:
///   - `inject(text:)` — pasteboard swap + Cmd+V. Works in every macOS app
///     including Electron/Chromium ones (Telegram, Slack, VSCode, Discord).
///     This is the v0.7.3.2 baseline path, used for the FINAL injection on
///     hotkey release.
///   - `partialReplace(text:)` — AX in-place replacement. Reads the current
///     selection range, writes new text to that range. Used for streaming
///     PARTIAL transcriptions during recording. Only works in apps that
///     expose `kAXSelectedTextRange` for write (native apps: TextEdit, Notes,
///     Mail, Pages, Safari, etc). In Electron/Chromium apps this method is
///     a graceful no-op — the user simply doesn't see partials in those apps,
///     but the final injection at commit still works (pasteboard+Cmd+V).
///
/// Why AX works for partials (the design that v0.8 marker got wrong):
///   - No marker character in the text — no marker = no word-boundary bug
///   - No keyboard nav (Option+Left, Shift+Ctrl+E) — no app-specific bindings
///   - Each partial REPLACES the previous partial wholesale: we track the
///     last partial's text length and re-select that range before writing.
///   - Apps that don't support AX write (Electron) just see no partials — no
///     duplicates, no deletions, no harm. Final pasteboard+Cmd+V still works.
final class TextInjector {

    /// Inject text at the current cursor position.
    /// - Parameter restorePasteboard: if true (default), use pasteboard+Cmd+V
    ///   and the transcribed text WILL land in the system clipboard. If false,
    ///   use the AX path that never touches the pasteboard — text appears at
    ///   the cursor but the clipboard is completely untouched (the user's
    ///   previous clipboard contents stay in place, and the transcription
    ///   does NOT appear in clipboard history at all).
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

        if restorePasteboard {
            injectViaPasteboard(text, restoreAfter: false)
        } else {
            // Try AX first (pasteboard-free). If the app doesn't support
            // kAXSelectedTextRange (Electron/Chromium), fall back to
            // pasteboard+Cmd+V so text still lands.
            if !injectViaAX(text) {
                logger.info("AX injection failed — falling back to pasteboard for this app")
                injectViaPasteboard(text, restoreAfter: true)
            }
        }
    }

    // MARK: - AX Direct Injection (pasteboard-free)

    /// Writes text directly to the focused element via Accessibility API.
    /// The system pasteboard is never touched — neither by us, nor by any
    /// paste-history snapshot. This is the right path when the user does
    /// NOT want the transcription in their clipboard.
    ///
    /// How it works:
    /// 1. Read the current selection range (where the cursor is)
    /// 2. Write the text into that selection via kAXSelectedTextAttribute
    ///    — this REPLACES whatever was selected, or inserts at the cursor
    ///    if nothing was selected
    ///
    /// Limitation: if a partial was in flight (lastPartialText set), we need
    /// to back-extend the selection by the partial's character count, then
    /// write the final text — otherwise the partial and final would both
    /// appear (partial then final appended after it).
    /// Returns true if AX injection succeeded, false if the app doesn't
    /// support kAXSelectedTextRange (Electron/Chromium case).
    @discardableResult
    private func injectViaAX(_ text: String) -> Bool {
        logger.info("Injecting via AX: \(text.count) chars (pasteboard-free)")

        guard let systemWide = AXUIElementCopySystemWide() else {
            logger.error("injectViaAX: no system-wide element")
            return false
        }
        guard let focused = systemWide.focusedElement() else {
            logger.error("injectViaAX: no focused element")
            return false
        }
        guard let textRange = focused.selectedTextRange() else {
            logger.error("injectViaAX: focused element doesn't expose kAXSelectedTextRange")
            return false
        }

        // If a partial is in flight, back-extend the selection to cover it,
        // so the final text REPLACES the partial (not appends after it).
        if let prev = lastPartialText, !prev.isEmpty {
            var range = CFRange()
            AXValueGetValue(textRange, .cfRange, &range)
            let cursor = range.location + range.length
            let backExtend = min(prev.count, 200)  // defensive cap (FIX-10)
            let newLocation = max(0, cursor - backExtend)
            let newLength = min(cursor, backExtend)
            var newRange = CFRange(location: newLocation, length: newLength)
            if let newRangeVal = AXValueCreate(.cfRange, &newRange) {
                AXUIElementSetAttributeValue(
                    focused,
                    kAXSelectedTextRangeAttribute as CFString,
                    newRangeVal
                )
            }
        }

        // Write the final text. This is a direct AX write — no pasteboard
        // swap, no Cmd+V, no history snapshot taken.
        let writeResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if writeResult != .success {
            logger.error("injectViaAX: kAXSelectedText write failed (err=\(writeResult.rawValue))")
            return false
        }

        // No lastPartialText to track — AX path doesn't need it. Clear state
        // so the next recording doesn't try to back-extend against stale data.
        clearPartial()
        return true
    }

    // MARK: - Pasteboard + Cmd+V

    private func injectViaPasteboard(_ text: String, restoreAfter: Bool) {
        logger.info("Injecting via pasteboard: \(text.count) chars (restoreAfter=\(restoreAfter))")

        // FIX-17: drop the Right-arrow "collapse selection" hack from FIX-11.
        // The Right arrow was being intercepted by destination apps'
        // keyboard shortcut handlers — most notably Telegram, which uses
        // Right arrow (with sticky Option modifier from the released
        // hotkey) to navigate between chats in the chat list. Result:
        // mid-dictation, Telegram would steal focus to a different chat
        // and the injected text would land there. The selection-collapse
        // benefit (avoiding Cmd+V replacing a user's selected range)
        // was theoretical — in practice the user explicitly clicks into
        // a field to dictate, and if they have a non-empty selection
        // they can press Delete first.
        //
        // We DO still need to handle the "user has text selected" case
        // somehow, but posting synthetic arrow keys is the wrong tool.
        // The proper fix is AX-based: read kAXSelectedTextRange, if
        // non-empty, write "" to it to clear, then paste. Out of scope
        // for this patch — just drop the broken shortcut.

        let pasteboard = NSPasteboard.general
        let savedContents = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        // Write our text. Use clearContents + setString (not declareTypes)
        // because declareTypes makes clipboard managers/vaults see the write
        // as an APPEND (new entry in history) rather than a REPLACE.
        // The vault user was seeing the transcription in "second position"
        // because of this. clearContents + setString looks like a clean
        // replace to the vault, so the transcription doesn't pollute history.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Tiny delay so the pasteboard swap is observable by the destination app
        usleep(20_000) // 20ms

        // Simulate Cmd+V
        postKeyCombo(keyCode: 0x09, flags: .maskCommand) // V

        // Restore original pasteboard content (best-effort).
        // When restoreAfter=false (clipboard copy ON), skip — the transcription
        // stays at position 1 so the user can Cmd+V it elsewhere.
        guard restoreAfter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let _ = self else { return }
            let currentCount = pasteboard.changeCount
            let expectedCount = savedChangeCount + 1  // we wrote once
            if currentCount == expectedCount {
                // No one else touched the pasteboard — safe to restore.
                if let saved = savedContents {
                    pasteboard.clearContents()
                    pasteboard.setString(saved, forType: .string)
                } else {
                    pasteboard.clearContents()
                }
            }
            // else: clipboard was touched by another app — leave it alone.
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

    // MARK: - AX In-Place Partial Replace (v0.9.1)

    /// Tracks the last partial text we wrote via AX, so the next partial
    /// (or the final commit) can re-select that range and replace it.
    /// Nil = no partial injected yet (or app doesn't support AX write).
    private var lastPartialText: String?

    /// Streaming partial injection. Replaces the previous partial (or, on
    /// first call, inserts at the cursor) with the new partial text.
    /// Returns true if the injection succeeded, false if the app doesn't
    /// support AX write (no partials shown in that app, but final commit
    /// via pasteboard+Cmd+V will still work).
    @discardableResult
    func partialReplace(text: String) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return false
        }

        guard let systemWide = AXUIElementCopySystemWide() else {
            return false
        }
        guard let focused = systemWide.focusedElement() else {
            return false
        }

        // We need a writable text range. Read the current selection range,
        // then expand it (or shrink it) to cover the previous partial length.
        // On first call, we just insert at the cursor (no selection).
        guard let textRange = focused.selectedTextRange() else {
            return false
        }

        if let prev = lastPartialText, !prev.isEmpty {
            // Replace previous partial: extend the selection back by prev.count
            // characters. AX positions are character indices within the text
            // of the focused element.
            var range = CFRange()
            AXValueGetValue(textRange, .cfRange, &range)

            // Current cursor position is location + length (end of selection).
            // We want to select from (cursor - prev.count) to cursor, then
            // write the new text — that REPLACES prev with text.
            //
            // FIX-10: defensive cap. If lastPartialText was somehow populated
            // with a very long string (e.g. stale state from a prior
            // session that was never cleared), this back-extend would wipe
            // out a huge chunk of preceding text. Partials are short —
            // cap at 200 chars which is plenty for ~5-10s of speech.
            let backExtend = min(prev.count, 200)
            let cursor = range.location + range.length
            let newLocation = max(0, cursor - backExtend)
            let newLength = min(cursor, backExtend)

            var newRange = CFRange(location: newLocation, length: newLength)
            guard let newRangeVal = AXValueCreate(.cfRange, &newRange) else {
                return false
            }
            let setResult = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, newRangeVal)
            if setResult != .success {
                // App doesn't expose kAXSelectedTextRange for write — this is
                // the Electron/Chromium case. Graceful no-op.
                logger.debug("partialReplace: app doesn't support AXSelectedTextRange write (err=\(setResult.rawValue))")
                return false
            }
        }
        // else: no previous partial — cursor is at the end of the existing
        // selection (or empty selection at insert point). We just write.

        // Now write the new partial text into the selected range.
        let writeResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if writeResult != .success {
            logger.debug("partialReplace: kAXSelectedText write failed (err=\(writeResult.rawValue))")
            return false
        }

        lastPartialText = text
        return true
    }

    /// Returns true if a streaming partial is currently in flight (we
    /// need to remove it before the final commit can pasteboard+Cmd+V).
    var hasPendingPartial: Bool {
        return lastPartialText != nil
    }

    /// The number of characters in the last injected partial. Used by
    /// the commit path to know how many characters to delete before the
    /// final pasteboard+Cmd+V (so the final text replaces the partial
    /// rather than appending after it).
    var lastPartialLength: Int {
        return lastPartialText?.count ?? 0
    }

    /// Clear the partial tracking state. Call this on commit (after the
    /// partial has been removed) and on cancel.
    func clearPartial() {
        lastPartialText = nil
    }

    /// Select the last `lastPartialLength` characters before the cursor and
    /// delete them. Used by the commit path to remove the last in-place
    /// partial before pasteboard+Cmd+V injects the final text.
    /// Returns true on success.
    ///
    /// FIX-8: Always clear `lastPartialText` regardless of success/failure.
    /// Previously, a failed AX delete would leave the stale text in
    /// `lastPartialText`, causing the NEXT recording's first partial to
    /// compute `cursor - prev.count` and back-select that many characters —
    /// wiping out the previous recording's final injected text.
    @discardableResult
    func deleteLastPartial() -> Bool {
        guard let prev = lastPartialText, !prev.isEmpty else { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            // FIX-8: still clear — the partial text is useless to the next
            // recording if we couldn't delete it via AX. The next recording's
            // partial will not try to back-extend against stale state.
            clearPartial()
            return false
        }
        guard let systemWide = AXUIElementCopySystemWide() else {
            clearPartial()
            return false
        }
        guard let focused = systemWide.focusedElement() else {
            clearPartial()
            return false
        }
        guard let textRange = focused.selectedTextRange() else {
            clearPartial()
            return false
        }

        var range = CFRange()
        AXValueGetValue(textRange, .cfRange, &range)

        let cursor = range.location + range.length
        let newLocation = max(0, cursor - prev.count)
        let newLength = min(cursor, prev.count)

        var newRange = CFRange(location: newLocation, length: newLength)
        guard let newRangeVal = AXValueCreate(.cfRange, &newRange) else {
            clearPartial()
            return false
        }
        let setResult = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, newRangeVal)
        if setResult != .success {
            clearPartial()
            return false
        }

        // Replace selection with empty string (delete)
        let writeResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            "" as CFString
        )
        // FIX-8: always clear, even on write failure, so stale state can't
        // leak into the next recording.
        clearPartial()
        if writeResult != .success { return false }
        return true
    }
}

// MARK: - AXUIElement helpers

private extension AXUIElement {
    /// The currently focused UI element (the AX focus owner). This is the
    /// element text fields expose for reading/writing.
    func focusedElement() -> AXUIElement? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(self, kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let ref else { return nil }
        return (ref as! AXUIElement)
    }

    /// The element's selected text range (CFRange), if writable. Returns
    /// nil if the element doesn't expose this attribute.
    func selectedTextRange() -> AXValue? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(self, kAXSelectedTextRangeAttribute as CFString, &ref)
        guard err == .success, let ref else { return nil }
        return (ref as! AXValue)
    }
}

private func AXUIElementCopySystemWide() -> AXUIElement? {
    return AXUIElementCreateSystemWide()
}
