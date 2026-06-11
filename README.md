# WhisperFlow

A local-first, offline voice-to-text dictation tool for macOS. Press a hotkey, speak, release — transcribed text appears at your cursor in any app. No cloud, no subscription.

**Current version: v0.10** — mlx-whisper daemon, grammar mode toggle, mic energy diagnostics, gated debug logging.

---

## Changelog (v0.7 → v0.10)

| Version | What changed |
|---|---|
| **v0.10** (this release) | `MicEnergyTracker` wired up — reports mic signal quality per session. `WF_DEBUG` env var gates verbose per-buffer/per-key logs. |
| **v0.8** | `GrammarCorrector` now mode-driven: `.autoPunctuate` (capitalize + add `.` at end, default) or `.raw` (preserve your punctuation verbatim). Toggle via menu. |
| **v0.7.3** | Continuous recording mode: double-tap the hotkey to record without holding. Any key commits, Esc/Backspace cancels. 5-min hard cap. |
| **v0.7.2** | Engine picker (subprocess / daemon) + Model picker (base.en / small.en) in menu bar. |
| **v0.7** | Replaced `SFSpeechRecognizer` with `mlx-whisper` subprocess + optional persistent Unix-socket daemon. ~50ms daemon latency vs ~1.5-2.2s subprocess. |

---

## Architecture

```
Ctrl+Option held (or double-tap for continuous)
      │
      ▼
HotkeyManager          ← CGEvent tap (global, any app) + 100ms poll
      │
      ▼
AVAudioEngine          ← mic tap, raw PCM buffers
      │
      ▼
TranscriptionController ← writes 16kHz mono Float32 WAV to /tmp
      │
      ▼
[Engine picker: subprocess 1.5–2.2s | daemon 50–80ms]
      │
      ▼
mlx-whisper            ← Apple Silicon MLX (GPU/ANE), local model
      │
      ▼
FillerWordCleaner      ← sound-only non-lexical vocalizations
                          (uh/um/ah/erm/hmm — NOT meaningful words)
      │
      ▼
GrammarCorrector       ← mode-aware (see below)
      │
      ▼
TextInjector           ← pasteboard swap + Cmd+V
```

**Grammar mode** (toggle via menu bar → Grammar):
- `.autoPunctuate` (default): capitalize sentence starts + append `.` if missing. Good for prose/chat.
- `.raw`: no capitalization, no punctuation added. Preserves your spoken output verbatim. Use for commands, n8n nodes, code, terminal input.

**Engine modes:**
| Engine | Per-call latency | Idle RAM | Model |
|---|---|---|---|
| `subprocess` (default) | 1.5–2.2s | 0 MB | loaded fresh each call |
| `daemon` | 50–80ms | ~1.4 GB (small.en) | resident in RAM |

**Models:** `base.en` (~810 MB) or `small.en` (~1.4 GB), selectable via menu.

---

## Requirements

- macOS 13.0+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4) — mlx-whisper is ARM/MLX-native
- **Python 3.9+** with `mlx-whisper` installed: `pip install mlx-whisper`
- Xcode 15+ / Swift 5.9+ (for building from source)
- **No sandbox** (required for global CGEvent tap)

## Install mlx-whisper

```bash
pip install mlx-whisper
```

Models are downloaded automatically on first use (~800 MB–1.4 GB depending on model).

## Build

```bash
chmod +x build.sh

# Build only
./build.sh build

# Build + install to /Applications
./build.sh install

# Generate Xcode project for editing
./build.sh xcode
```

## Permissions Setup

WhisperFlow needs three permissions. Grant them **before first launch**:

| Permission | Where | Why |
|---|---|---|
| Microphone | System Settings → Privacy & Security → Microphone | Record audio |
| Speech Recognition | System Settings → Privacy & Security → Speech Recognition | Required by macOS for any audio input |
| Accessibility | System Settings → Privacy & Security → Accessibility | Global hotkey + text injection |

Accessibility is the critical one. Without it, `CGEvent.tapCreate` silently fails and the hotkey does nothing.

Run `./build.sh permissions` to print step-by-step instructions.

## Usage

1. Launch WhisperFlow — a mic icon appears in your menu bar
2. Place cursor anywhere (any app — TextEdit, VS Code, browser, Terminal...)
3. **Hold Ctrl+Option** → mic icon fills (recording starts)
4. Speak naturally
5. **Release Ctrl+Option** → text appears at cursor after ~50–80ms (daemon) or ~1.5–2.2s (subprocess)

**Alternative hotkey:** Ctrl+Shift (select via menu bar → Hotkey)

**Continuous mode (no hold required):**
1. Double-tap the hotkey quickly (within 1 second)
2. Icon changes to `mic.fill.badge.plus` — recording continues
3. Speak — release is ignored
4. Press any key to commit, Esc/Backspace to cancel
5. Auto-commits after 5 minutes

**Menu options:**
- **Engine**: subprocess (zero idle RAM) vs daemon (fast, ~1GB idle)
- **Grammar**: auto-punctuate vs raw (no period appended)
- **Model**: base.en (balanced) vs small.en (most accurate)
- **Hotkey**: Ctrl+Shift vs Ctrl+Option

## File Map

```
WhisperFlow/
├── Sources/WhisperFlow/
│   ├── WhisperFlowApp.swift         ← @main, SwiftUI scene (no window)
│   ├── AppDelegate.swift            ← lifecycle, menu bar, log gating (WF_DEBUG)
│   ├── HotkeyManager.swift          ← CGEvent tap + 100ms poll, Ctrl+Shift/Ctrl+Option
│   ├── TranscriptionController.swift ← pipeline orchestrator, writes WAV, mic energy
│   ├── TranscriptionDaemon.swift     ← NWConnection Unix-socket client
│   ├── FillerWordCleaner.swift      ← sound-only filler regex (uh/um/ah/...)
│   ├── GrammarCorrector.swift       ← mode-aware: autoPunctuate or raw
│   ├── GrammarConfig.swift          ← GrammarMode enum + UserDefaults
│   ├── TextInjector.swift           ← pasteboard + Cmd+V injection
│   ├── EngineConfig.swift            ← .subprocess / .daemon
│   ├── ModelConfig.swift             ← .base.en / .small.en
│   ├── HotkeyConfig.swift            ← .ctrlShift / .ctrlOption
│   ├── PermissionsChecker.swift      ← mic + speech + accessibility checks
│   ├── MicEnergyTracker.swift        ← per-session mic RMS diagnostic
│   └── Info.plist                    ← LSUIElement=true, usage descriptions
├── WhisperFlow.entitlements         ← mic + speech; NO sandbox
├── Package.swift                    ← SPM manifest
├── build.sh                          ← build/install script
└── README.md                        ← this file
```

## Diagnostic logging

WhisperFlow writes logs to `/tmp/wf-app.log`. Two verbosity levels:

**Default (quiet):** Only state transitions, errors, and injection events are logged.

**Debug mode (`WF_DEBUG=1`):** Also logs per-buffer audio format, per-key hotkey events, per-state transitions. Enable before launching:

```bash
export WF_DEBUG=1
wf start
```

Or add to the app's `LSEnvironment` in Info.plist.

The `MicEnergyTracker` reports signal quality at the end of every session:
```
[WF:Mic] ✓ mic input flowing — peak=0.0495 (-26.1dB), avg=0.0081, above-threshold buffers: 12/26
[WF:Mic] ⚠ MIC INPUT SILENT — peak=0.0011 (-59.4dB), avg=0.0005, buffers=6
```
Silent input typically means a Bluetooth headset is in A2DP (output-only) mode — check System Settings → Bluetooth → WI-C100 → Audio Mode = HFP/Headset.

## Privacy

- All audio processing happens on your Mac's Neural Engine via mlx-whisper
- The daemon and subprocess both run locally; no network requests are made
- The app has no network entitlements and makes no outbound connections
- Microphone audio is never written to disk (only the temporary WAV buffer in `/tmp`, deleted immediately after transcription)
- `~/.cache/huggingface/hub/` holds the model weights (~800 MB–1.4 GB)

## Known Limitations

- **English only** — change `Locale(identifier: "en-US")` in `TranscriptionController` for other languages
- **No VAD** — release the hotkey to stop recording (intentional; VAD caused first-part loss during pauses in testing)
- **Hotkey fixed** — Ctrl+Shift or Ctrl+Option only (no custom trigger key yet)
- **A2DP Bluetooth headsets** — WI-C100 and similar BT headsets may switch to output-only mode mid-session. The `MicEnergyTracker` detects this; switch to HFP mode in Bluetooth settings or use a wired mic.

## Planned Improvements

- [x] v0.8 grammar mode toggle ✓
- [x] v0.10 MicEnergyTracker wiring ✓
- [ ] Streaming partial results (show transcription as you speak)
- [ ] Settings UI window (SwiftUI) — hotkey picker, filler list, language selection
- [ ] Whisper Core ML (swap mlx-whisper for whisper.cpp + Core ML)
- [ ] App Store build (requires replacing CGEvent tap with Carbon `RegisterEventHotKey`)

## App Store Distribution

The current CGEvent tap approach requires disabling the sandbox, which blocks App Store submission. For MAS distribution:
- Replace `CGEvent.tapCreate` with Carbon `RegisterEventHotKey` (sandboxable)
- Replace CGEvent injection with `AXUIElementSetAttributeValue` (requires per-app handling)
- This significantly increases complexity — out of scope for MVP