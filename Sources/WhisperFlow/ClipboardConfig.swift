import Foundation

/// Controls whether the transcribed text is left in the clipboard after injection.
///
/// When OFF (default): the clipboard is restored to its previous contents
/// ~800ms after the Cmd+V paste, so the user's clipboard is untouched.
///
/// When ON: the transcribed text remains in the clipboard after injection,
/// making it easy to paste elsewhere. The original clipboard content is lost.
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
