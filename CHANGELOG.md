# Changelog

All notable changes to WhisperFlow.

## 0.9.8 — 2026-08-26

### Changed
- **Daemon engine is now the default** for a better first-run experience:
  50–80ms transcription instead of a 1.5–2.2s subprocess wait. The daemon
  auto-starts with the app, and its ~1.4GB is released on quit via graceful
  shutdown in `applicationWillTerminate`. Subprocess remains available in
  Settings for memory-constrained machines.

## 0.9.7 — 2026-08-26

### Fixed
- **Event-tap memory leak** — pass-through events were retained and never
  released; the app leaked on every keystroke/click system-wide.
- **Menu-bar freeze** — audio-engine setup (up to ~3s BT route-negotiation
  wait) no longer runs on the main thread; capture lifecycle moved to a
  dedicated serial queue.
- **Warm-up race** — launch warm-up uses a throwaway engine; a hotkey press
  during the first 3 seconds can no longer lose its recording tap.
- **Daemon client data race** — receive buffer is lock-confined with a single
  outstanding receive; truncated responses report as timeout instead of a
  misleading JSON parse failure.
- **Out-of-order partials** — only one partial transcription in flight at a
  time; older partials can no longer overwrite newer ones at the cursor.
- **Stale idle-flip race** — deferred icon flips are generation-guarded and
  can't reset the status icon during an active recording.

### Changed
- Transcripts log to `~/Library/Logs/WhisperFlow/app.log` (0600) instead of
  world-readable `/tmp/wf-app.log`.
- Speech Recognition permission is no longer requested (SFSpeechRecognizer was
  never used).
- `wf-transcribe` / `wf-transcribe-daemon` paths resolve from the user's home
  directory (was hardcoded); missing wrapper logs a warning.
- PID-file fallback verifies the process path via `proc_pidpath` before
  sending SIGTERM (stale-PID safety).
- Subprocess stderr drained after process exit — diagnostics no longer lose
  the tail.
- Zero compiler warnings; dead code removed (`leadingPattern`,
  `splitSentences`, unused flags).

### Added
- First-run **Setup & Troubleshooting window**: live permission checklist,
  direct System Settings deep links, backend detection. Also available any
  time from the menu-bar menu.
- `VERSION` file — build.sh stamps it into Info.plist (single source of truth).
- MIT LICENSE file.

## 0.9.6 — 2026-06-21

- Properly trigger A2DP→HFP route negotiation (start engine before format poll)
- Pasteboard-free keystroke injection for Electron apps (clipboard vault no longer polluted)

## 0.9.5 — 2026-06-19

- Fix first-press hotkey miss, BT mic warm-up, Electron injection fallback

## 0.9.4 — 2026-06-18

- Post-review code-quality pass: crash-safe WAV cleanup, pasteboard race guard,
  AVAudioConverter cache, log size cap, question-word grammar guard

## 0.9.3 — 2026-06-17

- Settings window (runtime cadence + partials toggle)
- Delete last partial before final inject (no double text)

## 0.9.1 — 2026-06-16

- AX in-place streaming partials — text appears at cursor during recording
