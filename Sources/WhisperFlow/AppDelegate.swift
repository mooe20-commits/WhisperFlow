import AppKit
import Carbon
import OSLog

private let logger = Logger(subsystem: "com.whisperflow", category: "AppDelegate")

/// Tee NSLog to a file for reliable diagnostics on ad-hoc signed Sequoia builds.
///
/// FIX-B3: previous implementation opened and closed `/tmp/wf-app.log` on every
/// call. With calls from the CGEvent tap thread, audio tap thread, and several
/// background queues (partial flush, daemon client, transcription subprocess),
/// concurrent open/seek/write/close sequences could interleave and produce
/// garbled/overlapping log content. Now uses a single serial queue + one
/// long-lived FileHandle, lazily opened.
private final class WfLogWriter {
    static let shared = WfLogWriter()
    private let queue = DispatchQueue(label: "wf.log", qos: .utility)
    private var handle: FileHandle?
    // FIX-P1 (v0.9.7): moved from /tmp/wf-app.log to ~/Library/Logs/WhisperFlow/.
    // /tmp is world-readable and this log contains dictation transcript text
    // ("injecting: ...") — user-private content must not be world-readable.
    // ~/Library/Logs already has 0700 perms on the user subtree; we also
    // chmod the file to 0600 defensively.
    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WhisperFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()
    private let maxBytes: UInt64 = 5 * 1024 * 1024  // 5MB cap
    private let keepBytes: UInt64 = 1 * 1024 * 1024  // keep last 1MB on truncate

    func write(_ msg: String) {
        queue.sync {
            // Truncation check on every write — cheap (single stat() call)
            // and keeps the log from unbounded growth.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64, size > maxBytes {
                truncate(size: size)
            }
            if handle == nil {
                // FIX-W1: FileHandle(forWritingTo:) requires the file to
                // exist. If /tmp/wf-app.log was cleaned up (reboot, /tmp
                // rotation, manual rm) or never existed, the handle was
                // nil and every wfLog call silently no-op'd. The stderr
                // write below still worked, so the user saw logs in
                // `log show` but the file they were tailing was empty
                // or missing. Create the file if it doesn't exist.
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
                }
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            let line = "[\(Date())] \(msg)\n"
            let data = Data(line.utf8)
            // Always also write to stderr as a backup channel — visible in
            // Console.app and `log show` even when /tmp/wf-app.log is rotated
            // away or unwritable.
            FileHandle.standardError.write(data)
            handle?.write(data)
        }
    }

    private func truncate(size: UInt64) {
        guard let readHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? readHandle.close() }
        let keepOffset = size > keepBytes ? size - keepBytes : 0
        readHandle.seek(toFileOffset: keepOffset)
        let tail = readHandle.readDataToEndOfFile()

        handle.flatMap { try? $0.close() }
        try? FileManager.default.removeItem(at: url)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        handle = try? FileHandle(forWritingTo: url)
        let banner = "[... log truncated (was \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) ...]\n"
        handle?.write(Data(banner.utf8))
        handle?.write(tail)
    }
}

func wfLog(_ msg: String) {
    WfLogWriter.shared.write(msg)
}

/// Debug-only log. Same behavior as wfLog, but gated by the `WF_DEBUG`
/// environment variable. Use for noisy per-buffer / per-keycode lines
/// that flood /tmp/wf-app.log during normal operation.
///
/// Enable: `export WF_DEBUG=1` in the launching shell (or set on the
/// .app's `LSEnvironment` if launching via launchd).
let isWFDebugLogging: Bool = ProcessInfo.processInfo.environment["WF_DEBUG"] != nil

func wfLogD(_ msg: String) {
    guard isWFDebugLogging else { return }
    wfLog(msg)
}

/// Ensure a `Process` has a PATH that includes common CLI tool locations
/// (Homebrew, MacPorts, /usr/local). The .app bundle inherits launchd's
/// minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) which breaks tools that
/// shell out to ffmpeg, git, etc. Used for both the transcribe subprocess
/// and the daemon launch.
func setSanePATH(on proc: Process) {
    let extras = ["/opt/homebrew/bin", "/opt/homebrew/sbin",
                  "/usr/local/bin", "/usr/local/sbin",
                  "/opt/local/bin"]
    let current = proc.environment?["PATH"]
        ?? ProcessInfo.processInfo.environment["PATH"]
        ?? ""
    var parts = current.split(separator: ":").map(String.init)
    for extra in extras where FileManager.default.fileExists(atPath: extra) {
        if !parts.contains(extra) {
            parts.insert(extra, at: 0)
        }
    }
    var env = proc.environment ?? ProcessInfo.processInfo.environment
    env["PATH"] = parts.joined(separator: ":")
    proc.environment = env
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotkeyManager: HotkeyManager?
    private var transcriptionController: TranscriptionController?
    private var permissionsChecker: PermissionsChecker?
    private var hotkeyStatusItem: NSMenuItem?
    private var settingsWindowController: SettingsWindowController?
    private var modelMenuItems: [WhisperModel: NSMenuItem] = [:]
    private var engineMenuItems: [TranscriptionEngine: NSMenuItem] = [:]
    private var hotkeyMenuItems: [HotkeyPreset: NSMenuItem] = [:]
    private var grammarMenuItems: [GrammarMode: NSMenuItem] = [:]
    private var fillerMenuItems: [FillerMode: NSMenuItem] = [:]
    /// FIX-12: Streaming partials toggle (separate from cadence since it's
    /// a single on/off choice, not a mode enum). nil until menu is built.
    private var partialMenuItem: NSMenuItem?
    private var clipboardMenuItem: NSMenuItem?
    /// True once `startHotkeyListener()` has successfully called `register()`.
    /// Used to detect the "AX was 0 at launch, user just granted it" case
    /// where the menu recheck needs to kick the listener into life.
    private var hotkeyListenerActive = false
    /// Minimum milliseconds the transcribing state must remain visible before
    /// the icon can flip back to idle. Prevents a state that's too fast to
    /// notice (the daemon completes in<100ms on short utterances). 300ms
    /// is perceptible without feeling sluggish.
    private let transcribingMinDurationMs: Int = 300
    /// Timestamp (Date) when we entered the `.transcribing` state. Used to
    /// enforce `transcribingMinDurationMs` before allowing the icon to flip
    /// back to idle.
    private var transcribingStartTime: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — menu bar only
        NSApp.setActivationPolicy(.accessory)

        wfLog("[WF:App] launch — WF_DEBUG=\(isWFDebugLogging ? "1" : "0") bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        NSLog("[WF:App] launch — WF_DEBUG=%@", isWFDebugLogging ? "1" : "0")

        setupMenuBar()
        setupDependencies()
        checkPermissionsAndStart()
    }

    private func setupDependencies() {
        transcriptionController = TranscriptionController()
        hotkeyManager = HotkeyManager()
        permissionsChecker = PermissionsChecker()

        // Surface capture errors (e.g. "no input device") to the user as a
        // brief status bar notification — otherwise the icon flips, nothing
        // happens, and the user is left wondering why.
        transcriptionController?.onError = { [weak self] message in
            self?.showCaptureError(message)
        }
        // Revert the status icon from ".transcribing" back to ".idle" once
        // the full pipeline (transcription + post-processing) finishes.
        // Enforce a minimum visible duration so the transcribing state is
        // perceptible even when the daemon completes in <100ms.
        transcriptionController?.onTranscriptionComplete = { [weak self] in
            guard let self else { return }
            let elapsed = -(self.transcribingStartTime?.timeIntervalSinceNow ?? 999.0)
            let remaining = (self.transcribingMinDurationMs - Int(elapsed * 1000))
            if remaining > 0 {
                // Too fast — flip back after the remaining time.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(remaining)) {
                    self.updateStatusIcon(recording: .idle)
                }
            } else {
                // Already past the minimum — flip back immediately.
                self.updateStatusIcon(recording: .idle)
            }
        }
        // Surface daemon errors (connection fail, model crash, bad JSON) in
        // the status bar so the user knows why transcription was slower
        // (subprocess fallback adds ~1.5s latency vs daemon's ~0.1s).
        transcriptionController?.onDaemonError = { [weak self] message in
            self?.showCaptureError(message)
        }
        // v0.9.1: stream partial results via AX in-place replace in the
        // destination app. Works in native apps (TextEdit, Notes, Mail,
        // Pages, Safari); graceful no-op in Electron/Chromium apps that
        // don't expose kAXSelectedTextRange for write (Telegram, Slack,
        // VSCode, Discord — they still get the final text via the
        // pasteboard+Cmd+V path on commit). TC owns the textInjector and
        // handles the partial injection internally.
    }

    /// Briefly show a capture error in the status label so the user sees
    /// WHY nothing was recorded. The status label auto-reverts on the next
    /// hotkey down/up cycle.
    ///
    /// FIX-W3: previously the icon was left at whatever state `onHotkeyDown`
    /// had flipped it to (mic.fill for PTT, or stuck at ellipsis.circle if
    /// the user had already released). User saw a stuck "transcribing"
    /// state forever after a failed capture. Now we also force the icon
    /// back to idle so the menu bar doesn't lie about recording state.
    private func showCaptureError(_ message: String) {
        wfLog("[WF:App] capture error shown to user: \(message)")
        NSLog("[WF:App] capture error: %@", message)
        // FIX-W3: reset icon to idle so the user isn't staring at a stale
        // mic.fill or ellipsis.circle after a failed capture. The error
        // message itself is in the label, so the failure is still visible.
        updateStatusIcon(recording: .idle)
        DispatchQueue.main.async { [weak self] in
            let hotkeyLabel = HotkeyConfig.current().statusLabel
            self?.hotkeyStatusItem?.title = "Hotkey: \(hotkeyLabel) ⚠️ \(message)"
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperFlow")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "WhisperFlow", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let hotkeyItem = NSMenuItem(title: "Hotkey: \(HotkeyConfig.current().statusLabel) (idle)", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false   // gray label, not a clickable item
        hotkeyStatusItem = hotkeyItem   // keep a ref so we can update it
        menu.addItem(hotkeyItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check Permissions", action: #selector(checkPermissions), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())

        // ── Hotkey picker (Ctrl+Shift vs Ctrl+Option) ──
        for preset in HotkeyPreset.allCases {
            let item = NSMenuItem(
                title: preset.displayName,
                action: #selector(selectHotkey(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = HotkeyPreset.allCases.firstIndex(of: preset) ?? 0
            hotkeyMenuItems[preset] = item
            menu.addItem(item)
        }
        refreshHotkeyMenuState()

        menu.addItem(NSMenuItem.separator())

        // ── Engine picker (subprocess vs daemon) ──
        for engine in TranscriptionEngine.allCases {
            let item = NSMenuItem(
                title: engine.displayName,
                action: #selector(selectEngine(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = TranscriptionEngine.allCases.firstIndex(of: engine) ?? 0
            engineMenuItems[engine] = item
            menu.addItem(item)
        }
        refreshEngineMenuState()

        menu.addItem(NSMenuItem.separator())

        // ── Grammar mode (auto-punctuate vs raw) ──
        // v0.8: opt-in for users who dictate commands/code, where appending
        // a period to "git status" → "git status." is wrong.
        for mode in GrammarMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectGrammar(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = GrammarMode.allCases.firstIndex(of: mode) ?? 0
            grammarMenuItems[mode] = item
            menu.addItem(item)
        }
        refreshGrammarMenuState()

        menu.addItem(NSMenuItem.separator())

        // ── Filler cleanup (standard vs disabled) ──
        // v0.10: toggle filler-word removal. Standard removes uh/um/like
        // etc. Disabled passes them through verbatim.
        for mode in FillerMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectFiller(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = FillerMode.allCases.firstIndex(of: mode) ?? 0
            fillerMenuItems[mode] = item
            menu.addItem(item)
        }
        refreshFillerMenuState()

        menu.addItem(NSMenuItem.separator())

        // ── Streaming partials toggle (FIX-12) ──
        // When ON, partial transcriptions are AX-injected into the
        // destination app during capture (live feedback). When OFF, only
        // the final text is injected on hotkey release. Default is OFF
        // because the AX partial path interacts badly with some apps'
        // selection state (triple-clicked lines get replaced).
        let partialItem = NSMenuItem(
            title: "Streaming partials (live preview)",
            action: #selector(toggleStreamingPartials(_:)),
            keyEquivalent: ""
        )
        partialItem.target = self
        partialMenuItem = partialItem
        menu.addItem(partialItem)
        refreshStreamingPartialState()

        // Copy-to-clipboard toggle (top-level menu — frequent toggle)
        menu.addItem(NSMenuItem.separator())
        let clipboardItem = NSMenuItem(
            title: "Copy transcription to clipboard",
            action: #selector(toggleClipboardCopy(_:)),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        clipboardMenuItem = clipboardItem
        menu.addItem(clipboardItem)
        refreshClipboardCopyState()

        menu.addItem(NSMenuItem.separator())

        // ── Model picker ──
        for model in WhisperModel.allCases {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = WhisperModel.allCases.firstIndex(of: model) ?? 0
            modelMenuItems[model] = item
            menu.addItem(item)
        }
        // Apply the current selection (read from config file) on launch.
        refreshModelMenuState()

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func checkPermissionsAndStart() {
        wfLog("[WF:App] checkPermissionsAndStart (launch path)")

        // If the user has the daemon engine selected, auto-start the daemon
        // before hotkey listening begins. This way it's ready by the time
        // the user presses Ctrl+Shift.
        if EngineConfig.current() == .daemon {
            ensureDaemonRunning()
        }

        permissionsChecker?.requestAllPermissions { [weak self] granted in
            // The permission flow is non-trivial (mic → speech → accessibility
            // → fallback prompts) so each step gets a real log line.
            wfLog("[WF:App] requestAllPermissions returned granted = \(granted ? 1 : 0)")
            DispatchQueue.main.async {
                if granted {
                    wfLog("[WF:App] starting hotkey listener")
                    self?.startHotkeyListener()
                    // Pre-warm the transcription model so the first real
                    // transcription doesn't suffer a ~10s cold-start penalty.
                    self?.transcriptionController?.warmUpModel()
                } else {
                    wfLog("[WF:App] showing permissions alert")
                    self?.showPermissionsAlert()
                }
            }
        }
    }

    private func startHotkeyListener() {
        let preset = HotkeyConfig.current()
        hotkeyManager = HotkeyManager()
        guard let hotkeyManager, let transcriptionController else { return }

        // PTT (single tap + hold): same behavior as before
        hotkeyManager.onHotkeyDown = {
            // Frequent (every PTT press) — debug only. The matching
            // PTT UP at the end of the recording is the actionable one.
            wfLogD("[WF:App] hotkey DOWN callback — starting capture")
            logger.info("Hotkey pressed — starting capture")
            transcriptionController.startCapture()
            self.updateStatusIcon(recording: .ptt)
        }
        hotkeyManager.onHotkeyUp = {
            // ALWAYS log PTT UP — this is the user committing their
            // recording, important for "where did my audio go" debugging.
            wfLog("[WF:App] hotkey UP callback — stopping capture")
            logger.info("Hotkey released — stopping capture")
            transcriptionController.stopCapture()
            // Show transcribing state while the daemon/subprocess works.
            // AppDelegate flips back to .idle on onTranscriptionComplete.
            self.updateStatusIcon(recording: .transcribing)
        }

        // v0.7.3: continuous mode (double-tap)
        // Start is identical to PTT start (just begin capturing).
        hotkeyManager.onContinuousStart = {
            // ALWAYS log continuous START — rare event, important state transition.
            wfLog("[WF:App] continuous START — capture continues after hotkey release")
            logger.info("Continuous recording started")
            // Defensive: only start if not already capturing (shouldn't happen
            // since the state machine guards this, but cheap insurance).
            transcriptionController.startCapture()
            self.updateStatusIcon(recording: .continuous)
        }
        // Stop = commit (any key, or 5-min cap). Same as PTT release: transcribe.
        hotkeyManager.onContinuousStop = {
            wfLog("[WF:App] continuous STOP — committing buffer")
            logger.info("Continuous recording stopped (commit)")
            transcriptionController.stopCapture()
            self.updateStatusIcon(recording: .idle)
        }
        // Cancel = discard (Esc/Backspace/Delete). No transcribe, no paste.
        hotkeyManager.onContinuousCancel = {
            wfLog("[WF:App] continuous CANCEL — discarding buffer")
            logger.info("Continuous recording cancelled (discard)")
            transcriptionController.cancelCapture()
            self.updateStatusIcon(recording: .idle)
        }

        hotkeyManager.register(preset: preset)
        hotkeyListenerActive = true
        wfLog("[WF:App] hotkey listener started (combo=\(preset.displayName))")
        logger.info("Hotkey listener started")
    }

    /// v0.10: four visual states — idle, PTT (filled mic), continuous
    /// (filled mic with badge), transcribing (ellipsis while daemon works).
    /// The transcribing state bridges the gap between hotkey UP (end of
    /// recording) and the injection callback (transcription complete).
    private enum StatusState { case idle, ptt, continuous, transcribing }

    private func updateStatusIcon(recording: StatusState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let symbolName: String
            let label: String
            switch recording {
            case .idle:
                symbolName = "mic"
                label = "(idle)"
                self.transcribingStartTime = nil
            case .ptt:
                symbolName = "mic.fill"
                label = "(● recording)"
                self.transcribingStartTime = nil
            case .continuous:
                symbolName = "mic.fill.badge.plus"
                label = "(● continuous — Esc cancels, any key/click commits)"
                self.transcribingStartTime = nil
            case .transcribing:
                symbolName = "ellipsis.circle"
                label = "(● transcribing)"
                self.transcribingStartTime = Date()
            }
            self.statusItem?.button?.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "WhisperFlow"
            )
            let hotkeyLabel = HotkeyConfig.current().statusLabel
            self.hotkeyStatusItem?.title = "Hotkey: \(hotkeyLabel) \(label)"
        }
    }

    @objc private func checkPermissions() {
        wfLog("[WF:App] checkPermissions (menu path)")
        NSLog("[WF:App] checkPermissions (menu path)")
        permissionsChecker?.requestAllPermissions { [weak self] granted in
            wfLog("[WF:App] menu recheck returned granted = \(granted ? 1 : 0)")
            NSLog("[WF:App] menu recheck returned granted = %d", granted ? 1 : 0)
            DispatchQueue.main.async {
                guard let self else { return }

                // If the listener never started (e.g. AX was 0 at launch and
                // the user just granted it via this menu path), start it now.
                // Otherwise the alert below would tell the user "everything's
                // fine" while the hotkey still doesn't work.
                if granted && !self.hotkeyListenerActive {
                    wfLog("[WF:App] permissions just granted — starting hotkey listener")
                    NSLog("[WF:App] permissions just granted — starting hotkey listener")
                    self.startHotkeyListener()
                }

                let msg = granted ? "All permissions granted ✓" : "Accessibility permission not working (CDHash mismatch after rebuild).\n\nFix: System Settings → Privacy & Security → Accessibility → remove WhisperFlow → re-add it. Then try \"Check Permissions\" again."
                let alert = NSAlert()
                alert.messageText = "WhisperFlow Permissions"
                alert.informativeText = msg
                if !granted {
                    // Give the user a "relaunch" button. On Sequoia, AX grants
                    // sometimes don't refresh in the running process — the
                    // self-relaunch path is the reliable fix.
                    alert.addButton(withTitle: "Relaunch WhisperFlow")
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Later")
                    let resp = alert.runModal()
                    if resp == .alertFirstButtonReturn {
                        wfLog("[WF:App] user picked relaunch to refresh AX")
                        self.relaunchSelf()
                    } else if resp == .alertSecondButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                } else {
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openSettings() {
        wfLog("[WF:App] openSettings")
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    /// Relaunch the app via `open` and quit the current process. This is the
    /// reliable way to pick up a freshly granted Accessibility permission on
    /// macOS Sequoia — `AXIsProcessTrusted()` caches the old (denied) state
    /// in the running process and won't refresh until relaunch.
    private func relaunchSelf() {
        let appPath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [appPath]
        do {
            try task.run()
            // CRITICAL: waitUntilExit() is required here. task.run() is
            // asynchronous — it returns immediately after spawning the new
            // process. Without waitUntilExit(), NSApp.terminate fires before
            // open has finished launching the new instance, and the new process
            // gets killed along with the old one.
            task.waitUntilExit()
            wfLog("[WF:App] relaunch open completed (exit=\(task.terminationStatus)), quitting self")
            NSLog("[WF:App] relaunch open completed (exit=%d)", task.terminationStatus)
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            wfLog("[WF:App] relaunch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine Picker

    /// Called when the user clicks an engine item in the menu. If they
    /// pick "daemon", we try to auto-start the daemon process; if they
    /// pick "subprocess" while the daemon is running, we shut it down to
    /// release the ~1GB model from RAM.
    @objc private func selectEngine(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < TranscriptionEngine.allCases.count else { return }
        let chosen = TranscriptionEngine.allCases[idx]

        let previous = EngineConfig.current()
        EngineConfig.set(chosen)
        wfLog("[WF:App] engine set to \(chosen.shortName) (was \(previous.shortName))")
        NSLog("[WF:App] engine set to %@ (was %@)", chosen.shortName, previous.shortName)
        refreshEngineMenuState()

        // FIX-9: act on the change. If user picked daemon, launch it now
        // (not on next app launch) so the very next dictation is fast.
        // If user picked subprocess, stop any running daemon to free RAM.
        if chosen == .daemon {
            ensureDaemonRunning()
        } else if chosen == .subprocess {
            stopDaemon()
        }
    }

    /// Ask the daemon to shut itself down and wait for the process to exit.
    /// This releases the model's RAM. Idempotent: no-op if the daemon isn't
    /// running.
    private func stopDaemon() {
        guard TranscriptionDaemon.isRunning() else {
            wfLog("[WF:App] stopDaemon: daemon not running, nothing to do")
            return
        }

        // Try a graceful shutdown via the socket first. If that fails,
        // fall back to SIGTERM via the PID file.
        let client = TranscriptionDaemon()
        var graceful = false
        do {
            let resp = try client.sendShutdown()
            graceful = (resp["ok"] as? Bool) == true
        } catch {
            wfLog("[WF:App] stopDaemon: graceful shutdown failed: \(error)")
        }

        if !graceful, let pidStr = try? String(contentsOfFile: TranscriptionDaemon.pidPath, encoding: .utf8),
           let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            wfLog("[WF:App] stopDaemon: falling back to SIGTERM on pid \(pid)")
            kill(pid, SIGTERM)
        }

        // Wait for the process to actually exit (max 3s)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if !TranscriptionDaemon.isRunning() {
                wfLog("[WF:App] stopDaemon: daemon exited, RAM released")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        wfLog("[WF:App] stopDaemon: WARNING — daemon still running after 3s")
    }

    private func refreshEngineMenuState() {
        let active = EngineConfig.current()
        for (engine, item) in engineMenuItems {
            item.state = (engine == active) ? .on : .off
        }
    }

    // MARK: - Hotkey Picker

    /// Called when the user clicks a hotkey preset in the menu. Switching
    /// presets takes effect immediately: we tear down the old CGEvent tap
    /// and re-register with the new combo.
    @objc private func selectHotkey(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < HotkeyPreset.allCases.count else { return }
        let chosen = HotkeyPreset.allCases[idx]

        HotkeyConfig.set(chosen)
        wfLog("[WF:App] hotkey preset set to \(chosen.displayName)")
        NSLog("[WF:App] hotkey preset set to %@", chosen.displayName)
        refreshHotkeyMenuState()
        updateStatusIcon(recording: .idle)

        // Tear down the existing tap and re-register with the new combo
        hotkeyManager = nil
        startHotkeyListener()
    }

    private func refreshHotkeyMenuState() {
        let active = HotkeyConfig.current()
        for (preset, item) in hotkeyMenuItems {
            item.state = (preset == active) ? .on : .off
        }
    }

    /// Launch the daemon via /usr/bin/python3 in the background, detached
    /// from the Swift app's process group. Idempotent: no-op if already
    /// running.
    private func ensureDaemonRunning() {
        if TranscriptionDaemon.isRunning() {
            wfLog("[WF:App] daemon already running, skipping launch")
            return
        }
        wfLog("[WF:App] launching wf-transcribe-daemon...")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Resolved from the current user's home directory (no hardcoded paths).
        let daemonScript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/wf-transcribe-daemon")
        proc.arguments = [daemonScript.path]
        // Inject homebrew paths so the daemon can find ffmpeg when mlx_whisper
        // shells out to it during model load + transcribe.
        setSanePATH(on: proc)
        // FIX-B4: append-mode log file. Previous code used createFile (truncates)
        // + FileHandle(forWritingTo:) (no O_APPEND), so daemon print() calls
        // would interleave and overwrite each other from offset 0, losing the
        // previous run's log. Now we seek to end before handing the fd to the
        // process — every run appends, no data loss on restart.
        let logFile = "/tmp/wf-daemon.log"
        let logURL = URL(fileURLWithPath: logFile)
        // Ensure the file exists; forUpdating fails otherwise.
        if !FileManager.default.fileExists(atPath: logFile) {
            FileManager.default.createFile(atPath: logFile, contents: nil)
        }
        if let fh = try? FileHandle(forUpdating: logURL) {
            fh.seekToEndOfFile()
            proc.standardOutput = fh
            proc.standardError = fh
        }
        do {
            try proc.run()
            wfLog("[WF:App] daemon launch initiated, pid=\(proc.processIdentifier)")
            // FIX-B5: don't Thread.sleep on main — that froze app launch by
            // 500ms. The reachability check is diagnostic, not required for
            // correctness (daemon will be ready by the first real transcription,
            // and the subprocess fallback covers any race).
            //
            // FIX-B6: previous 0.5s wait was too short to verify model load —
            // it would log a misleading "WARNING" while the daemon was still
            // loading. Now we wait 2s in the background (well past socket bind
            // AND model load for both base.en and small.en), and only log a
            // debug line if still unreachable.
            DispatchQueue.global(qos: .utility).async {
                Thread.sleep(forTimeInterval: 2.0)
                if TranscriptionDaemon.isReachable() {
                    wfLog("[WF:App] daemon reachable on socket")
                } else {
                    wfLogD("[WF:App] daemon not reachable after 2s — may still be loading model")
                }
            }
        } catch {
            wfLog("[WF:App] failed to launch daemon: \(error.localizedDescription)")
        }
    }

    // MARK: - Grammar Mode Picker

    /// Called when the user clicks a grammar mode item in the menu. Takes
    /// effect on the NEXT transcription (no app bounce needed).
    @objc private func selectGrammar(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < GrammarMode.allCases.count else { return }
        let chosen = GrammarMode.allCases[idx]

        GrammarConfig.set(chosen)
        wfLog("[WF:App] grammar mode set to \(chosen.shortName)")
        NSLog("[WF:App] grammar mode set to %@", chosen.shortName)
        refreshGrammarMenuState()
    }

    private func refreshGrammarMenuState() {
        let active = GrammarConfig.current()
        for (mode, item) in grammarMenuItems {
            item.state = (mode == active) ? .on : .off
        }
    }

    // MARK: - Filler Mode Picker

    /// Called when the user clicks a filler mode item in the menu. Takes
    /// effect on the NEXT transcription (no app bounce needed).
    @objc private func selectFiller(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < FillerMode.allCases.count else { return }
        let chosen = FillerMode.allCases[idx]

        FillerConfig.set(chosen)
        wfLog("[WF:App] filler mode set to \(chosen.shortName)")
        NSLog("[WF:App] filler mode set to %@", chosen.shortName)
        refreshFillerMenuState()
    }

    private func refreshFillerMenuState() {
        let active = FillerConfig.current()
        for (mode, item) in fillerMenuItems {
            item.state = (mode == active) ? .on : .off
        }
    }

    // MARK: - Streaming Partials Toggle (FIX-12)

    /// Called when the user clicks the streaming partials menu item.
    /// Flips the setting immediately and updates the checkmark.
    @objc private func toggleStreamingPartials(_ sender: NSMenuItem) {
        let newValue = !StreamingConfig.currentPartialEnabled()
        StreamingConfig.setPartialEnabled(newValue)
        wfLog("[WF:App] streaming partials set to \(newValue ? "ON" : "OFF")")
        NSLog("[WF:App] streaming partials set to %@", newValue ? "ON" : "OFF")
        refreshStreamingPartialState()
    }

    private func refreshStreamingPartialState() {
        partialMenuItem?.state = StreamingConfig.currentPartialEnabled() ? .on : .off
    }

    // MARK: - Clipboard Copy Toggle

    /// Called when the user clicks the clipboard copy menu item.
    /// Flips the setting immediately and updates the checkmark.
    @objc private func toggleClipboardCopy(_ sender: NSMenuItem) {
        let newValue = !ClipboardConfig.isEnabled()
        ClipboardConfig.setEnabled(newValue)
        wfLog("[WF:App] copy-to-clipboard set to \(newValue ? "ON" : "OFF")")
        NSLog("[WF:App] copy-to-clipboard set to %@", newValue ? "ON" : "OFF")
        refreshClipboardCopyState()
    }

    private func refreshClipboardCopyState() {
        clipboardMenuItem?.state = ClipboardConfig.isEnabled() ? .on : .off
    }

    // MARK: - Model Picker

    /// Called when the user clicks a model item in the menu. The sender's
    /// `.tag` is the index into `WhisperModel.allCases`.
    @objc private func selectModel(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < WhisperModel.allCases.count else { return }
        let chosen = WhisperModel.allCases[idx]

        guard ModelConfig.setModel(chosen) else {
            wfLog("[WF:App] failed to switch model to \(chosen.shortName)")
            return
        }
        wfLog("[WF:App] model switched to \(chosen.rawValue)")
        NSLog("[WF:App] model switched to %@", chosen.rawValue)
        refreshModelMenuState()
    }

    /// Re-read the current model from the config file and update checkmarks.
    /// Called on launch and after the user picks a new model.
    private func refreshModelMenuState() {
        let active = ModelConfig.currentModel()
        wfLog("[WF:App] active model = \(active.rawValue)")
        for (model, item) in modelMenuItems {
            item.state = (model == active) ? .on : .off
        }
    }

    private func showPermissionsAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = """
        WhisperFlow's Accessibility permission isn't working — even though it shows as enabled in System Settings.

        This happens after rebuilding the app (ad-hoc signing changes the code identity, orphaning the old TCC entry).

        Fix: System Settings → Privacy & Security → Accessibility → remove WhisperFlow → re-add it. Then click "Check Permissions" in the WhisperFlow menu.

        Toggling the existing checkbox ON/OFF won't fix a CDHash mismatch — the entry must be fully removed and re-added.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}
