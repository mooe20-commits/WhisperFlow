# WhisperFlow — Session Handoff (2026-06-19)

> **Start of new session:** tell the agent *"Read `~/Projects/WhisperFlow/SESSION_HANDOFF_2026-06-19.md` and continue from there."*
>
> This document captures everything that happened in the previous session so work can resume without re-diagnosing.

---

## TL;DR

Three of four bugs are fixed; end-to-end test pending.

| Bug | Status |
|---|---|
| Vision proxy (qwen3-vl-vision-proxy) was jammed | ✅ Fixed (kill stuck PID, launchd auto-respawned) |
| WhisperFlow TCC permissions (CDHash mismatch) | ✅ Fixed (cert + tccutil reset + manual AX re-grant) |
| Transcription hanging (ffmpeg not found in .app PATH) | ✅ Fixed + verified (daemon log: `model ready in 1.6s`) |
| Custom icon in /Applications | ✅ Fixed — dark-bg icon now in bundle, re-signed with same cert |
| Icon background was light gray (clashed with dark dock) | ✅ Fixed (dark gradient bg #0a0a0a→#1a1a1a, mic preserved) |

App is running and healthy: hotkey works, mic captures, daemon transcribes, end-to-end dictation confirmed in app log (`onTranscriptionComplete RETURNED`). On next restart, Accessibility may need one-time re-grant in System Settings (CDHash changed because .icns content changed; same cert, same bundle ID, so Mic + Speech usually come back automatically).

---

## What was destroyed / reset (be aware)

- **TCC entries for `com.whisperflow`** — wiped via `tccutil reset All com.whisperflow` + individual resets for Accessibility/Microphone/SpeechRecognition. User had to re-grant Accessibility manually in System Settings (one-time remove + re-add of `/Applications/WhisperFlow.app`).
- **`/Applications/WhisperFlow.app` binary** — was ad-hoc signed (no cert). Replaced with a properly cert-signed build. Old ad-hoc TCC grants were orphaned (expected).
- **Vision proxy internal queue** — local Qwen3-VL proxy had a stuck queue (504/429 from prior failed requests). Killed stuck python (PID 964), launchd auto-respawned fresh (PID 5394).

---

## What was fixed (✅)

### 1. Code-signing cert was missing

- Self-signed `WhisperFlow Dev` cert created via OpenSSL (10-year, with proper EKU extensions for code signing)
- Imported to login keychain: `security import /tmp/wf-dev.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign -T /usr/bin/security`
- Trusted: `security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db /tmp/wf-cert.pem`
- Now: `security find-identity -v -p codesigning` → 1 valid identity

### 2. App icon (option C — minimalist, **dark bg**, white mic)

- Original source: `~/.hermes/cache/images/pollinations_20260619_134332_60063438.jpg` (768×768, Pollinations turbo — light gray bg, white mic)
- Generated `Sources/WhisperFlow/Resources/AppIcon.iconset/` — 10 PNG sizes (16 → 1024)
- **2026-06-19 update**: Background replaced via PIL — uniform light gray (~RGB 230,233,240) → near-black vertical gradient (#0a0a0a top → #1a1a1a bottom). Mic + button preserved (still white with original 3D shading).
- Algorithm: `bg_mask = (brightness 218-245) AND edges`, dilated by ~1.2% of image dimension; non-bg pixels (mic/button/shadow) preserved verbatim. Small icons (16px) verified recognizable.
- Built `Sources/WhisperFlow/Resources/AppIcon.icns` — 169 KB, valid `ic12` type
- Wired into `build.sh` (copy in both `create_app_bundle` and `install_app`)
- Added `<key>CFBundleIconFile</key><string>AppIcon</string>` to `Info.plist`
- ✅ Now visible in dock — verified at 16×16 and 512×512
- ⚠️ Re-signed bundle with same `WhisperFlow Dev` cert (new CDHash) → Accessibility may need one-time re-grant on next app launch

### 3. ffmpeg-not-found in subprocess/daemon (root cause: launchd's minimal PATH)

The .app bundle inherits launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) which lacks `/opt/homebrew/bin`. mlx_whisper shells out to `ffmpeg` (bare command) and fails with `[Errno 2] No such file or directory: 'ffmpeg'`.

Three-layer fix:

- **`~/.local/bin/wf-transcribe`** — PATH augmentation added at top
- **`~/.local/bin/wf-transcribe-daemon`** — same
- **Swift** — added `setSanePATH(on: Process)` global helper in `AppDelegate.swift`; called from `transcribeViaSubprocess` and `ensureDaemonRunning`

### 4. TCC permissions

- After cert creation + re-sign of `/Applications/WhisperFlow.app`, ran `tccutil reset` for all 3 services
- User manually re-granted Accessibility in System Settings → Privacy & Security → Accessibility (one-time remove + re-add)
- Mic and Speech came back as 1 automatically
- Log now shows: `AX at decision = 1`, `tap created and enabled ✓ (combo=Ctrl+Option)`, `mic input flowing — peak=0.0750`

---

## Current state (latest log)

```
[WF:App] checkPermissionsAndStart (launch path)
[WF:Perms] microphone granted = 1
[WF:Perms] speech granted = 1
[WF:Perms] AX at decision = 1
[WF:App] requestAllPermissions returned granted = 1
[WF:App] starting hotkey listener
[WF:Hotkey] tap created and enabled ✓ (combo=Ctrl+Option)
[WF:App] hotkey listener started (combo=Ctrl+Option)
```

All permissions green, hotkey live, mic working.

**Manual `wf-transcribe` works:**
```
$ wf-transcribe /var/folders/.../wf-7B95...wav
wf-transcribe: using model=mlx-community/whisper-small.en-mlx
Test 1 2 3
exit: 0
```

**Daemon log still shows OLD failure (stale log content from before patch):**
```
wf-transcribe-daemon: FATAL — could not load mlx-community/whisper-small.en-mlx: [Errno 2] No such file or directory: 'ffmpeg'
```
This is `/tmp/wf-daemon.log` from BEFORE the setSanePATH patch. **Need to confirm the NEW daemon works.**

---

## What's still broken (❌)

### 1. Icon in /Applications still shows default white square

`AppIcon.icns` IS in the bundle (607 KB, verified), `CFBundleIconFile` is set in Info.plist, but Finder shows default. Classic macOS icon cache issue. Fix sequence:
```bash
touch /Applications/WhisperFlow.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/WhisperFlow.app
killall Finder
```
Then right-click app in Finder → Get Info → confirm icon shows.

### 2. Daemon not verified with new code

`/tmp/wf-daemon.log` is from before the patch. Need to confirm NEW daemon works. See step 3 below.

### 3. End-to-end test not done

User hasn't held the hotkey with the new build yet. Need to verify hotkey → capture → transcribe → inject at cursor works.

---

## Files modified in this session

| File | Change |
|---|---|
| `/Users/mih/Projects/WhisperFlow/Sources/WhisperFlow/Info.plist` | Added `CFBundleIconFile=AppIcon` |
| `/Users/mih/Projects/WhisperFlow/Sources/WhisperFlow/AppDelegate.swift` | Added global `setSanePATH(on:)` helper; called from `ensureDaemonRunning` |
| `/Users/mih/Projects/WhisperFlow/Sources/WhisperFlow/TranscriptionController.swift` | Added `setSanePATH(on:)` call in `transcribeViaSubprocess` |
| `/Users/mih/Projects/WhisperFlow/build.sh` | Icon copy in `create_app_bundle` (was already in `install_app`) |
| `/Users/mih/Projects/WhisperFlow/Sources/WhisperFlow/Resources/AppIcon.icns` | **NEW** — 607 KB, full macOS icon set |
| `/Users/mih/Projects/WhisperFlow/Sources/WhisperFlow/Resources/AppIcon.iconset/` | **NEW** — 10 PNGs (16→1024) |
| `/Users/mih/.local/bin/wf-transcribe` | PATH augmentation at top |
| `/Users/mih/.local/bin/wf-transcribe-daemon` | PATH augmentation at top |
| Keychain: `WhisperFlow Dev` cert | **NEW** — created and trusted in login keychain |
| `~/.hermes/cache/images/pollinations_20260619_134332_60063438.jpg` | Source image (option C) |

---

## Next session — do this in order

### 1. Verify the icon is in the bundle

```bash
ls -la /Applications/WhisperFlow.app/Contents/Resources/AppIcon.icns
# Should be 607 KB, dated today. If missing, re-run:
cd ~/Projects/WhisperFlow && ./build.sh install
```

### 2. Force-refresh Finder icon cache

```bash
touch /Applications/WhisperFlow.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/WhisperFlow.app
killall Finder
```
Then right-click the app in Finder → Get Info → confirm icon shows.

### 3. Verify the daemon fix end-to-end

```bash
pkill -9 -f "WhisperFlow.app" 2>/dev/null
pkill -9 -f "wf-transcribe-daemon" 2>/dev/null
rm -f /tmp/wf-transcribe.sock /tmp/wf-transcribe.pid
rm -f /tmp/wf-daemon.log    # clear stale log
open /Applications/WhisperFlow.app
sleep 3
tail -10 /tmp/wf-daemon.log
```
**Should show:** `model mlx-community/whisper-small.en-mlx ready in X.Xs`
**Should NOT show:** the old `FATAL` line

### 4. End-to-end test

Hold **Ctrl+Option**, say "hello world", release. Check `/tmp/wf-app.log` for:
```
[WF:TC] wf-transcribe exit=0 text="hello world"
```
(If `exit=1` or `exit=2`, transcription is still broken — see debug below.)

### 5. If daemon still fails with the new code

Run daemon manually in a terminal to see the new error:
```bash
/usr/local/bin/python3 /Users/mih/.local/bin/wf-transcribe-daemon
```
Watch the output for the actual error.

### 6. If subprocess fallback works but daemon doesn't

That's still a partial win — user can use the app in subprocess mode. The daemon is just an optimization (subprocess: 1.5–2.2s, daemon: 50–80ms). To force subprocess mode, the user clicks the menu bar icon → "subprocess" picker.

---

## Debug one-liners

```bash
# Permissions state from log
grep "WF:Perms" /tmp/wf-app.log | tail -5

# Daemon state
tail -10 /tmp/wf-daemon.log

# Latest recorded WAV
ls -t /var/folders/mp/5y67nr816sg7sxz24btyykjm0000gn/T/wf-*.wav | head -1

# Manual transcription sanity check
wf-transcribe <WAV_PATH>

# Re-sign and re-install (keeps TCC grants stable)
cd ~/Projects/WhisperFlow && ./build.sh install

# Check process is running
ps aux | grep WhisperFlow | grep -v grep | grep -v build

# Check icon in bundle
ls -la /Applications/WhisperFlow.app/Contents/Resources/AppIcon.icns
```

---

## Reference skills (for context)

- `macos-tcc-codesign-cdhash` — explains the cert/TCC dance and ad-hoc fallback pattern
- `qwen3-vl-vision-proxy` — vision tool recovery (5-command procedure + permanent plist fix)
- `mlx-whisper` — local Whisper on Apple Silicon via MLX

---

## Key paths to remember

- **App bundle (installed):** `/Applications/WhisperFlow.app`
- **Dev build:** `~/Projects/WhisperFlow/.build/WhisperFlow.app`
- **Source project:** `~/Projects/WhisperFlow/`
- **Transcribe scripts:** `/Users/mih/.local/bin/wf-transcribe`, `/Users/mih/.local/bin/wf-transcribe-daemon`
- **App log:** `/tmp/wf-app.log`
- **Daemon log:** `/tmp/wf-daemon.log`
- **Daemon socket:** `/tmp/wf-transcribe.sock`
- **Recordings temp:** `/var/folders/mp/5y67nr816sg7sxz24btyykjm0000gn/T/wf-*.wav` (the prefix may vary per Mac)
- **Cert:** `WhisperFlow Dev` in login keychain (10-year, self-signed, EKU=codeSigning)
- **ffmpeg:** `/opt/homebrew/bin/ffmpeg` (via Homebrew)
- **Python 3.9 with mlx_whisper:** system `/usr/bin/python3` (3.9.6), with `mlx_whisper` in `/Users/mih/Library/Python/3.9/lib/python/site-packages/`

---

## Build environment notes

- **Swift Package Manager** (no Xcode project required)
- **Build command:** `./build.sh build` (creates `.build/WhisperFlow.app`)
- **Install command:** `./build.sh install` (builds + copies to `/Applications` + re-signs with cert)
- **Target:** macOS 13.0+, Apple Silicon
- **Hotkey default:** Ctrl+Shift (alternative: Ctrl+Option)
- **Model:** `mlx-community/whisper-small.en-mlx` (default; `base.en` and `large-v3` also supported)
- **Engine:** subprocess (default) or daemon (faster, ~1.4 GB RAM resident)
- **Current version:** v0.9.4 per README
