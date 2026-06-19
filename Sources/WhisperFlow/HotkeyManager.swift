import CoreGraphics
import Carbon
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.whisperflow", category: "HotkeyManager")

/// Tee to /tmp/wf-app.log for diagnostics (defined in AppDelegate.swift)
func wfLogH(_ msg: String) { wfLog(msg) }

/// Recording mode. v0.7.3: in addition to PTT, double-tap the hotkey to enter
/// continuous recording — release is ignored, capture continues until any
/// other keystroke (or the 5-minute cap) commits the buffer.
enum RecordingMode {
    case idle       // not recording
    case ptt        // push-to-talk: hold the hotkey, release to commit
    case continuous // double-tap armed: release is ignored, any key ends it
}

/// Registers a global hotkey using a CGEvent tap.
/// Requires Accessibility permission to intercept events system-wide.
///
/// The active combo is provided as a `HotkeyPreset` (see HotkeyConfig.swift).
/// Behavior:
/// - **Push-to-talk:** press and hold the combo to dictate, release to stop
///   and transcribe. (Single tap — first keydown of the combo.)
/// - **Continuous (double-tap):** tap the combo twice within 300ms. Recording
///   stays on after release; the *next* keypress (any key) commits the
///   buffer. Pressing Esc, Backspace, or Forward-Delete instead *cancels*
///   (discards the buffer, no paste). Hard cap: 5 minutes, then auto-commit.
/// - We swallow the modifier keyDown events (so they don't trigger the input
///   source switcher), but we let modifier keyUp events through (so the user
///   can still use Cmd+Tab or other shortcuts while the combo is held).
/// - Non-modifier keys (e.g. user types 'A' while holding the combo) are
///   swallowed in PTT mode, since the combo is "active" and we don't want
///   stray text.
final class HotkeyManager {
    // PTT / hotkey lifecycle
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?

    // Continuous mode (v0.7.3)
    var onContinuousStart: (() -> Void)?
    var onContinuousStop: (() -> Void)?    // commit (any key OR cap)
    var onContinuousCancel: (() -> Void)?  // discard (Esc / Backspace / Delete)

    /// How long after the first hotkey tap a second tap counts as a
    /// double-tap (and therefore enters continuous mode). 700ms is
    /// forgiving for human double-tapping — past testing showed 500ms
    /// was still too twitchy in practice.
    private let doubleTapWindow: TimeInterval = 1.0

    /// Hard cap on continuous recording length. After this, we auto-commit
    /// (just like the user pressed a key). 5 minutes.
    private let continuousMaxDuration: TimeInterval = 5 * 60

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var modifierMonitorTimer: Timer?
    private var continuousCapTimer: Timer?

    // FIX-5: pause the 100ms poll when idle to avoid unnecessary CPU wake.
    // The CGEvent tap handles the fast path; the poll is a fallback for
    // focus transitions. When mode == .idle and isHeld == false, the poll
    // does nothing useful — pausing it lets the app fully sleep.
    private var pollPaused = false

    private var preset: HotkeyPreset = .ctrlShift
    private var isHeld = false
    private var lastSeenFlags: CGEventFlags = []

    // v0.7.3: state machine
    private var mode: RecordingMode = .idle
    private var lastHotkeyKeydownAt: Date?
    private var continuousStartedAt: Date?
    /// The CGEventFlags that were active when continuous mode started.
    /// Used to detect when flagsChanged is the hotkey combo being released
    /// (no new modifiers pressed) vs. a genuinely new modifier signal.
    private var continuousEntryFlags: CGEventFlags = []

    /// Minimum time (seconds) that must elapse after entering continuous mode
    /// before a flagsChanged event is allowed to exit it. The hotkey-release
    /// event that follows a double-tap always arrives within ~100-150ms; any
    /// genuine "user released to commit" will be ≥300ms later.
    private let continuousMinDuration: TimeInterval = 0.30

    func register(preset: HotkeyPreset = HotkeyConfig.current()) {
        self.preset = preset
        // Stop any prior poll timer (defensive — caller's responsibility to
        // not have two HotkeyManager instances simultaneously)
        modifierMonitorTimer?.invalidate()
        modifierMonitorTimer = nil
        // Stop any leftover cap timer
        continuousCapTimer?.invalidate()
        continuousCapTimer = nil
        // Disable any prior tap (defensive)
        if let oldTap = eventTap {
            CGEvent.tapEnable(tap: oldTap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        isHeld = false
        lastSeenFlags = []
        mode = .idle
        lastHotkeyKeydownAt = nil
        continuousStartedAt = nil

        guard AXIsProcessTrusted() else {
            logger.error("Accessibility not granted — cannot register global hotkey")
            return
        }

        // Listen to keyboard events, flagsChanged (modifier toggles), AND
        // mouseDown (left click). The mouse click lets the user commit
        // continuous mode by clicking, e.g. into a text field to focus
        // before typing. flagsChanged catches modifier-only presses that
        // come through as events with no keycode.
        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)

        // Belt-and-suspenders: poll modifier state every 50ms. The event tap
        // can miss the very first event after launch (macOS quirk); the poll
        // is the reliable fallback and runs always — it's <0.1% CPU.
        pollPaused = false
        modifierMonitorTimer = Timer.scheduledTimer(
            withTimeInterval: 0.05, repeats: true
        ) { [weak self] _ in self?.pollModifierState() }

        // CGEvent callback — must be a C function pointer, so we use a trampoline.
        // The refcon pointer is created with passUnretained — no ownership transfer.
        // The runloop source is removed in deinit before self is deallocated, so
        // no callback fires after the HotkeyManager is gone. The original passUnretained
        // + takeUnretainedValue() pattern is correct — do not change to passRetained.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(type: type, event: event)
        }

        wfLogD("[WF:Hotkey] AX before tap = \(AXIsProcessTrusted() ? 1 : 0)")

        // Try .includeInactiveTap first — this lets the tap receive events
        // even when the app is in the background. If that fails (some macOS
        // configurations don't support it), fall back to .defaultTap.
        var tapOptions: CGEventTapOptions = .defaultTap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: CGEventTapOptions(rawValue: 3)!, // .defaultTap | .includeInactiveTap
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )
        if eventTap == nil {
            wfLogD("[WF:Hotkey] includeInactiveTap failed, trying .defaultTap")
            tapOptions = .defaultTap
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: tapOptions,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: selfPtr
            )
        }

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            wfLog("[WF:Hotkey] tap created and enabled ✓ (combo=\(preset.displayName))")
            logger.info("Global hotkey tap registered (\(preset.displayName))")
        } else {
            wfLog("[WF:Hotkey] FAILED tapCreate — AX=\(AXIsProcessTrusted() ? 1 : 0)")
            logger.error("Failed to create CGEvent tap — ensure Accessibility is granted")
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // FIX-5: Resume the poll when any tap event fires — the user may have
        // switched focus (tap missed it) and the poller is the fallback.
        pollPaused = false

        let flags = event.flags
        lastSeenFlags = flags

        // Only the modifiers we care about (mask out caps lock, num lock, fn, etc.)
        let relevantFlags = flags.intersection(preset.relevantMask)
        let isOurCombo = relevantFlags == preset.targetFlags
        let requiredFlags = preset.targetFlags
        // ─────────────────────────────────────────────────────────────────
        // Continuous mode: any user input ends the recording. We listen for:
        //   - keyDown (any character, function, arrow, etc.)
        //   - flagsChanged (modifier-only presses — Shift, Ctrl, Option, Cmd)
        //   - leftMouseDown (mouse click — useful for clicking into a field
        //     to focus before typing)
        // Esc/Backspace/Delete cancel (discard), everything else commits.
        // The hotkey combo itself is excluded (re-tapping the hotkey should
        // not end continuous mode — that would be a self-footgun).
        // ─────────────────────────────────────────────────────────────────
        if mode == .continuous, !isOurCombo {
            switch type {
            case .keyDown:
                let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                // kVK_Escape = 53, kVK_Delete = 51 (Backspace), kVK_ForwardDelete = 117
                let cancel = (keycode == 53 || keycode == 51 || keycode == 117)
                // ALWAYS log continuous stop/cancel — these are the user
                // committing their recording, important for debugging
                // "where did my audio go" complaints.
                wfLogH("[WF:Hotkey] continuous STOP via keycode=\(keycode) cancel=\(cancel)")
                NSLog("[WF:Hotkey] continuous STOP via keycode=%d cancel=%d", keycode, cancel ? 1 : 0)
                exitContinuous(cancel: cancel)
                // Swallow cancel keys so Backspace/Esc don't also fire in
                // the app behind us. Other keys pass through.
                return cancel ? nil : Unmanaged.passRetained(event)
            case .flagsChanged:
                // In continuous mode, flagsChanged fires for several reasons:
                // 1. The hotkey-release that immediately follows the double-tap
                //    gesture (~100ms after entry). Must NOT exit — this is the
                //    double-tap completing, not the user requesting a commit.
                // 2. Partial modifier release while still holding some of the
                //    combo — keep recording.
                // 3. All combo modifiers released well after entry — user is done
                //    speaking, commit.
                // 4. A genuinely new modifier pressed — commit.
                //
                // Guard: ignore all flagsChanged exits within the first
                // continuousMinDuration seconds. The double-tap release always
                // arrives within ~150ms; any genuine commit is much later.
                let elapsed = continuousStartedAt.map { Date().timeIntervalSince($0) } ?? 999
                let newRelevant = flags.intersection(preset.relevantMask)
                let newModifiers = newRelevant.subtracting(continuousEntryFlags)

                guard elapsed >= continuousMinDuration else {
                    // Debug-only: this fires on every hotkey release right
                    // after a double-tap (within ~100-150ms), which is
                    // expected behavior, not an error.
                    wfLogD("[WF:Hotkey] flagsChanged in continuous — within guard (\(String(format: "%.0f", elapsed * 1000))ms < \(Int(continuousMinDuration * 1000))ms), ignoring (newRelevant=\(newRelevant.rawValue))")
                    return Unmanaged.passRetained(event)
                }

                if !newModifiers.isEmpty {
                    // Genuinely new modifier pressed after guard — commit
                    wfLogH("[WF:Hotkey] continuous STOP via flagsChanged (new modifier \(newModifiers.rawValue)) elapsed=\(String(format: "%.2f", elapsed))s")
                    exitContinuous(cancel: false)
                    return Unmanaged.passRetained(event)
                }
                if newRelevant.isEmpty {
                    // All combo modifiers released after guard — commit
                    wfLogH("[WF:Hotkey] continuous STOP via flagsChanged (all modifiers released) elapsed=\(String(format: "%.2f", elapsed))s")
                    exitContinuous(cancel: false)
                    return Unmanaged.passRetained(event)
                }
                // Partial release (some combo modifiers still held) — keep recording
                // Debug-only: fires on every partial modifier release
                // during continuous mode, not actionable info.
                wfLogD("[WF:Hotkey] flagsChanged in continuous — partial release, keep recording (newRelevant=\(newRelevant.rawValue))")
                return Unmanaged.passRetained(event)
            case .leftMouseDown:
                wfLogH("[WF:Hotkey] continuous STOP via mouseDown")
                NSLog("[WF:Hotkey] continuous STOP via mouseDown")
                exitContinuous(cancel: false)
                // Let the click through — user is clicking into a field
                // to start typing, and we want the click to register.
                return Unmanaged.passRetained(event)
            default:
                break
            }
        }

        // ─────────────────────────────────────────────────────────────────
        // Hotkey keyDown: the combo just went down. Decide between PTT and
        // continuous (double-tap) based on the gap since the previous tap.
        // ─────────────────────────────────────────────────────────────────
        if type == .keyDown {
            // Always route through handleHotkeyDown when our combo fires.
            // The !isHeld guard was correct for repeated holds (don't re-fire
            // while the key is physically held), BUT it broke fast double-taps
            // where the second keyDown arrives before keyUp → isHeld still
            // true → handleHotkeyDown never called → no double-tap detected.
            // The poller tracks isHeld separately for the hold-detection case.
            if isOurCombo {
                isHeld = true
                handleHotkeyDown(source: "tap")
                // Swallow the keyDown so it doesn't reach other apps
                return nil
            }
            // We're in the combo, and the user pressed a non-modifier key
            // (e.g. they typed 'A' while still holding the combo in PTT).
            // Swallow it to keep the dictated buffer clean.
            if isHeld && mode == .ptt {
                let isModifier = !requiredFlags.intersection(flags).isEmpty
                              || flags.contains(.maskCommand)
                              || flags.contains(.maskAlternate)
                              || flags.contains(.maskControl)
                              || flags.contains(.maskShift)
                if !isModifier {
                    return nil
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────
        // Hotkey keyUp: PTT release commits, continuous release is ignored.
        // ─────────────────────────────────────────────────────────────────
        if type == .keyUp && isHeld {
            if !requiredFlags.isSubset(of: flags) {
                isHeld = false
                if mode == .ptt {
                    // PTT release — always log (this is the user committing
                    // a recording, important for "where did my audio go" debugging)
                    wfLogH("[WF:Hotkey] hotkey UP — PTT commit")
                    NSLog("[WF:Hotkey] hotkey UP — PTT commit")
                    mode = .idle
                    DispatchQueue.main.async { self.onHotkeyUp?() }
                    // Reset the double-tap window so a tap-release-tap-release
                    // pattern doesn't count as a double-tap.
                    lastHotkeyKeydownAt = nil
                } else if mode == .continuous {
                    wfLogD("[WF:Hotkey] hotkey UP — continuous ignores release")
                    // Keep isHeld false so we don't fire PTT callbacks if the
                    // user re-taps the combo. The continuous cap timer is
                    // still running and the next non-hotkey key will commit.
                }
                // LET THE MODIFIER KEYUP THROUGH — we don't want to eat it.
                return Unmanaged.passRetained(event)
            }
            // It's a keyUp of a non-modifier (shouldn't happen often) — swallow
            return nil
        }

        // Default: pass the event through
        return Unmanaged.passRetained(event)
    }

    /// Leave continuous mode, optionally cancelling the captured audio.
    /// Always called from the tap callback on the main thread? No — the tap
    /// runs on the runloop source thread, but the callbacks are dispatched
    /// async to main, so this function itself just mutates state and fires
    /// the right callback.
    private func exitContinuous(cancel: Bool) {
        guard mode == .continuous else { return }
        let startedAt = continuousStartedAt
        mode = .idle
        continuousStartedAt = nil
        continuousCapTimer?.invalidate()
        continuousCapTimer = nil
        isHeld = false
        // NOTE: lastHotkeyKeydownAt intentionally NOT cleared here.
        // We need the timestamp intact so subsequent double-tap attempts
        // still work. handleHotkeyDown will overwrite it with the next press.
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        wfLogH("[WF:Hotkey] exitContinuous cancel=\(cancel) duration=\(String(format: "%.2f", duration))s")
        NSLog("[WF:Hotkey] exitContinuous cancel=%d duration=%.2f", cancel ? 1 : 0, duration)
        if cancel {
            DispatchQueue.main.async { self.onContinuousCancel?() }
        } else {
            DispatchQueue.main.async { self.onContinuousStop?() }
        }
    }

    /// Schedule a timer that auto-commits continuous mode after the cap.
    /// Fires on the main run loop, so it can safely touch UI and callbacks.
    private func startContinuousCapTimer() {
        continuousCapTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: continuousMaxDuration, repeats: false
        ) { [weak self] _ in
            wfLogH("[WF:Hotkey] continuous cap (\(self?.continuousMaxDuration ?? 0)s) — auto-commit")
            NSLog("[WF:Hotkey] continuous cap auto-commit")
            self?.exitContinuous(cancel: false)
        }
        continuousCapTimer = timer
    }

    /// Polled every 100ms. Detects the combo going down/up via current event
    /// tap state, with a fallback to NSEvent.modifierFlags if the tap is silent.
    /// FIX-5: Returns early if the poll is paused (when idle) — avoids unnecessary
    /// CPU wake cycles while the app is sitting idle.
    private func pollModifierState() {
        guard !pollPaused else { return }

        let flags = lastSeenFlags.isEmpty
            ? CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.rawValue))
            : lastSeenFlags
        let relevant = flags.intersection(preset.relevantMask)
        let isOurCombo = relevant == preset.targetFlags

        // In continuous mode the poller just tracks isHeld for the keyUp path;
        // we never want to (re)fire onHotkeyDown — that would start a second
        // capture on top of the continuous one.
        // NOTE: We do NOT clear lastHotkeyKeydownAt here even when the hotkey
        // is released, because the tap swallows keyUp events and we need
        // that timestamp intact for double-tap detection on the next press.
        if mode == .continuous {
            if !isOurCombo && isHeld { isHeld = false }
            return
        }

        if isOurCombo && !isHeld {
            isHeld = true
            // v0.7.3.1: route through the shared hotkey-down handler so
            // double-tap detection works whether the event came from the
            // tap callback or the poller. Previously the poller bypassed
            // it and double-taps never registered.
            handleHotkeyDown(source: "poll")
        } else if !isOurCombo && isHeld {
            isHeld = false
            // Debug-only: this fires every 100ms during PTT hold, and
            // also once on PTT release. The tap-path UP is the canonical
            // "user committed" signal. Keep this for correlating poll
            // vs tap when double-tap detection is flaky.
            wfLogD("[WF:Hotkey:poll] hotkey UP")
            // Don't clear lastHotkeyKeydownAt — the tap already swallowed
            // keyUp; clearing it breaks double-tap on the next press.
            DispatchQueue.main.async { self.onHotkeyUp?() }
        }
    }

    /// Shared logic for "the hotkey combo just went down". Called from
    /// both the CGEvent tap callback and the 100ms poller so double-tap
    /// detection works regardless of which path delivers the event.
    /// - Parameter source: `"tap"` or `"poll"` — purely for log labeling.
    private func handleHotkeyDown(source: String) {
        let now = Date()
        let wasDoubleTap: Bool = {
            guard let last = lastHotkeyKeydownAt else { return false }
            return now.timeIntervalSince(last) < doubleTapWindow
        }()
        lastHotkeyKeydownAt = now

        if wasDoubleTap {
            // ALWAYS log double-tap — it's a rare event and the state
            // transition (entering continuous mode) is important to trace.
            wfLogH("[WF:Hotkey:\(source)] hotkey DOUBLE-TAP — entering continuous mode")
            NSLog("[WF:Hotkey:%@] DOUBLE-TAP — entering continuous", source)
            mode = .continuous
            // FIX: Reset isHeld so the stale keyUp from the first tap
            // (which arrives after the second keyDown in fast double-taps)
            // doesn't trigger a PTT commit or interfere with continuous mode.
            isHeld = false
            continuousStartedAt = now
            continuousEntryFlags = preset.targetFlags  // the hotkey combo's flags
            DispatchQueue.main.async { self.onContinuousStart?() }
            startContinuousCapTimer()
        } else {
            // PTT DOWN is frequent (every PTT press) — demote to debug
            // unless WF_DEBUG=1. The PTT UP at the end is the one that
            // matters for "did my recording land?" debugging.
            wfLogD("[WF:Hotkey:\(source)] hotkey DOWN — combo \(preset.displayName)")
            mode = .ptt
            DispatchQueue.main.async { self.onHotkeyDown?() }
        }
    }

    deinit {
        continuousCapTimer?.invalidate()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}
