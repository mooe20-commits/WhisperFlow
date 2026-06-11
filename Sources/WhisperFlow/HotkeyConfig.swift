import Foundation
import CoreGraphics

/// Hotkey preset — which set of modifier keys the user holds to dictate.
///
/// We only support pure-modifier combos (no trigger key) because the
/// existing `HotkeyManager` logic is built around modifier hold/release.
/// Adding a trigger key would be a much larger refactor; defer that
/// until someone actually needs it.
///
/// Two presets:
/// - `.ctrlShift`  (default, what the handoff says works on Polish layouts)
/// - `.ctrlOption` (alternative; **WARNING:** on many macOS keyboard
///   layouts Ctrl+Option is reserved for input-source switching.
///   On Polish keyboard it works, but switching layouts mid-session
///   may fight with the hotkey.)
enum HotkeyPreset: String, CaseIterable {
    case ctrlShift  = "ctrl+shift"
    case ctrlOption = "ctrl+option"

    var displayName: String {
        switch self {
        case .ctrlShift:  return "Ctrl+Shift"
        case .ctrlOption: return "Ctrl+Option"
        }
    }

    /// macOS display label for the menu (what the user sees in the top bar)
    var statusLabel: String {
        switch self {
        case .ctrlShift:  return "Ctrl+Shift"
        case .ctrlOption: return "Ctrl+Option"
        }
    }

    /// CGEventFlags the event tap / poll checks for
    var targetFlags: CGEventFlags {
        switch self {
        case .ctrlShift:  return [.maskControl, .maskShift]
        case .ctrlOption: return [.maskControl, .maskAlternate]
        }
    }

    /// Mask of which flags we care about (used to filter out caps lock, fn, etc.)
    var relevantMask: CGEventFlags {
        switch self {
        case .ctrlShift:  return [.maskControl, .maskShift]
        case .ctrlOption: return [.maskControl, .maskAlternate]
        }
    }
}

/// Persists the user's hotkey preset. Defaults to Ctrl+Shift (the
/// historically working combo on Polish keyboards).
enum HotkeyConfig {
    private static let key = "WFHotkeyPreset"

    static func current() -> HotkeyPreset {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let preset = HotkeyPreset(rawValue: raw)
        else {
            return .ctrlShift
        }
        return preset
    }

    @discardableResult
    static func set(_ preset: HotkeyPreset) -> Bool {
        UserDefaults.standard.set(preset.rawValue, forKey: key)
        return true
    }
}
