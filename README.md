# WhisperFlow — Local Voice-to-Text Dictation for macOS

## Overview

A **local-first, offline voice-to-text dictation tool** for macOS. Press a hotkey, speak, release — transcribed text appears at your cursor in any app. **No cloud, no subscription.**

> **Current version: v0.9.4** — AX in-place streaming partials, configurable cadence, Settings window, crash-safe WAV cleanup, pausable idle poll.

---

## What's New in v0.9.x

| Version | Highlights |
|---------|-----------|
| **v0.9.4** | Code quality fixes from post-review (crash-safe WAV, pasteboard race guard, pausable poll, AVAudioConverter cache, log size cap, question-word grammar guard, cert pre-check, .gitignore) |
| **v0.9.3** | Settings window — runtime cadence + partials toggle, delete last partial before final inject (no more double-text), SettingsWindowController + StreamingConfig |
| **v0.9.2** | Reduce AX partial flush interval from 1.5s → 1.0s |
| **v0.9.1** | AX in-place partial replacement — text appears at cursor during recording. Works in native apps (TextEdit, Notes, Mail, Safari); graceful no-op in Electron (Telegram, Slack, VSCode). Final inject still works everywhere via pasteboard+Cmd+V. |
| **v0.9.0** | Streaming partial transcription — first cut (panel approach, reverted in v0.9.1) |

---

## Architecture

```
Ctrl+Option held (or double-tap for continuous)
│
▼ AX in-place partials
HotkeyManager ← CGEvent tap (global, any app) + pausable 100ms poll
│
▼ WAV (16kHz mono PCM, ~/Library/Caches/)
AVAudioEngine ← mic tap, raw PCM buffers
│
▼ partial flush every N seconds (configurable)
TranscriptionController ← writes WAV, tracks byte offset
│
▼ [Engine: subprocess 1.5–2.2s | daemon 50–80ms]
TranscriptionDaemon ← Unix-socket client (or wf-transcribe subprocess)
│
▼ mlx-whisper ← Apple Silicon MLX (GPU/ANE), local model
│
▼ FillerWordCleaner ← sound-only filler words (uh/um/ah/erm/hmm)
│
▼ GrammarCorrector ← mode-aware punctuation
│
▼ TextInjector ← AX in-place replace (partials) + pasteboard+CmdV (final)
```

### Text Injection — Two Strategies

| Phase | Method | Works in |
|-------|--------|----------|
| During recording | AX in-place partial replacement at cursor | Native macOS apps (TextEdit, Notes, Mail, Pages, Safari) |
| On commit | Pasteboard swap + Cmd+V | Every macOS app (Electron, Chromium, native) |

In apps that don't support AX write (Telegram, Slack, VSCode, Discord), partials are silently skipped — the final pasteboard injection still works.

### Engine Comparison

| Engine | Per-call Latency | Idle RAM | Model |
|--------|-----------------|----------|-------|
| `subprocess` (default) | 1.5–2.2s | 0 MB | loaded fresh each call |
| `daemon` | 50–80ms | ~1.4 GB (small.en) | resident in RAM |

### Streaming Cadence

| Mode | Interval | Feel |
|------|----------|------|
| `fast` | 0.8s | Most "live", choppier updates |
| `balanced` (default) | 1.0s | Best balance — ~6 partials for 6s utterance |
| `slow` | 1.5s | Fewer writes, slightly sluggish |

### Grammar Modes

| Mode | Behavior | Best For |
|------|----------|----------|
| `.autoPunctuate` (default) | Capitalize sentence starts + append `.` if missing. Question-word guard (what/when/where/who/why/how/can/could/would/will/do/does/did/is/are/was/were) skips period. | Prose, chat |
| `.raw` | No capitalization, no punctuation added | Commands, code, terminal input |

---

## Requirements

- **macOS 13.0+** (Ventura or later)
- **Apple Silicon** (M1/M2/M3/M4) — mlx-whisper is ARM/MLX-native
- **Python 3.9+** with `mlx-whisper` installed
- **No sandbox** (required for global CGEvent tap and AX text injection)

---

## Installation

### Install mlx-whisper

```bash
pip install mlx-whisper
```

Models download automatically on first use (~800 MB–1.4 GB depending on model).

### Build

```bash
chmod +x build.sh

# Build only
./build.sh build

# Build + install to /Applications
./build.sh install

# Generate Xcode project
./build.sh xcode
```

---

## Permissions Setup

Grant these **before first launch**:

| Permission | Location | Purpose |
|------------|----------|---------|
| **Microphone** | System Settings → Privacy & Security → Microphone | Record audio |
| **Speech Recognition** | System Settings → Privacy & Security → Speech Recognition | Required by macOS for any audio input |
| **Accessibility** | System Settings → Privacy & Security → Accessibility | Global hotkey + AX text injection |

> ⚠️ **Accessibility is critical.** Without it, `CGEvent.tapCreate` silently fails and the hotkey does nothing.

Run `./build.sh permissions` to print step-by-step instructions.

---

## Usage

1. Launch WhisperFlow — a mic icon appears in the menu bar
2. Place cursor anywhere (any app)
3. **Hold Ctrl+Option** → icon fills (recording starts), partial text appears at cursor
4. Speak naturally
5. **Release Ctrl+Option** → final text lands at cursor

**Alternative hotkey:** Ctrl+Shift (select via menu bar → Hotkey)

### Continuous Mode (no hold required)

1. Double-tap the hotkey quickly (within 1 second)
2. Icon changes to indicate continuous recording
3. Speak — release is ignored
4. Press any key to commit, Esc/Backspace to cancel
5. Auto-commits after 5 minutes

### Settings Window

Click the menu bar icon → **Settings…** to configure:

- **Streaming cadence** (fast / balanced / slow)
- **Partial display** (on/off — disable for pasteboard-only mode)
- **Engine** (subprocess / daemon)
- **Model** (base.en / small.en)
- **Grammar** (auto-punctuate / raw)
- **Filler** (standard / off)
- **Hotkey** (Ctrl+Shift / Ctrl+Option)

---

## Diagnostic Logging

Logs written to `/tmp/wf-app.log` (5MB cap — rotates automatically).

**Quiet mode (default):** State transitions, errors, injection events only.

**Debug mode:** Enable with `WF_DEBUG=1` before launching, or add to `LSEnvironment` in Info.plist.

**MicEnergyTracker:** If you get empty transcripts, check the log for `[WF:Mic] ✓` or `[WF:Mic] ✗ SILENT INPUT` — the latter indicates the mic is in A2DP (output-only) mode.

---

## File Map

```
WhisperFlow/
├── Sources/WhisperFlow/
│   ├── WhisperFlowApp.swift          ← @main, SwiftUI scene (no window)
│   ├── AppDelegate.swift             ← lifecycle, menu bar, wfLog
│   ├── HotkeyManager.swift           ← CGEvent tap + pausable 100ms poll
│   ├── TranscriptionController.swift ← WAV writer, partial flush, pipeline
│   ├── TranscriptionDaemon.swift     ← NWConnection Unix-socket client
│   ├── FillerWordCleaner.swift       ← sound-only filler regex (uh/um/ah/...)
│   ├── FillerConfig.swift            ← FillerMode enum + UserDefaults
│   ├── GrammarCorrector.swift        ← mode-aware punctuation + question guard
│   ├── GrammarConfig.swift           ← GrammarMode enum + UserDefaults
│   ├── TextInjector.swift            ← AX in-place partial + pasteboard+CmdV
│   ├── StreamingConfig.swift         ← CadenceMode + partial enable/disable
│   ├── SettingsWindow.swift          ← SwiftUI settings window (tabbed)
│   ├── EngineConfig.swift            ← .subprocess / .daemon
│   ├── ModelConfig.swift             ← .base.en / .small.en
│   ├── HotkeyConfig.swift            ← .ctrlShift / .ctrlOption
│   ├── PermissionsChecker.swift      ← mic + speech + accessibility checks
│   ├── MicEnergyTracker.swift        ← per-session RMS diagnostic
│   └── Info.plist                    ← LSUIElement=true, usage descriptions
├── WhisperFlow.entitlements          ← mic + speech; NO sandbox
├── Package.swift                     ← SPM manifest
├── build.sh                          ← build/install/cert-check script
└── README.md
```