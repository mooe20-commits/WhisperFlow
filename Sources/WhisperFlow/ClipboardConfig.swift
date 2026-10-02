import Foundation

/// Controls whether the transcribed text is left in the clipboard after injection.
///
/// When OFF (default): pasteboard-free injection (AX write, or synthetic
/// keystrokes in Chromium) — the clipboard is never touched.
///
/// When ON: pasteboard+Cmd+V injection; the transcribed text remains in the
/// clipboard after injection, making it easy to paste elsewhere. The
/// original clipboard content is lost.
enum ClipboardConfig {
    private static let key = "WFCopyToClipboard"

    static func isEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: key)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: key)
        return true
    }
}
