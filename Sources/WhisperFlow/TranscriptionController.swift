import Foundation
import AVFoundation
import Speech
import OSLog

private let logger = Logger(subsystem: "com.whisperflow", category: "TranscriptionController")

// ---------------------------------------------------------------------------
// TranscriptionController — v0.6 (mlx-whisper subprocess)
//
// Architecture: file-based, no in-process STT.
//   • Hotkey DOWN  → start AVAudioEngine, write buffers to a temp WAV file
//   • Hotkey UP    → stop engine, flush WAV, shell out to `wf-transcribe`
//                    (Python wrapper around mlx-whisper), get text on stdout,
//                    run filler+grammar, inject at cursor
//
// Why this works where SFSpeechRecognizer failed:
//   SFSpeechRecognizer on macOS treats ~500ms silence as an utterance
//   boundary, dropping audio after the pause (the bug we could not fix).
//   mlx-whisper processes a complete audio file as one stream — pauses are
//   preserved. Cost: ~1.5s transcription latency for a 5s clip (one-time
//   10s model load on first call).
//
// Format conversion is preserved: BT mic delivers a format mlx-whisper can
// read directly via Python's `wave` module, but we normalize to 16kHz mono
// Float32 anyway for consistency with what ffmpeg produces.
// ---------------------------------------------------------------------------
final class TranscriptionController {

    // Dependencies
    var onResult: ((String) -> Void)?
    /// Called when capture fails to start (e.g. no input device). AppDelegate
    /// uses this to surface a user-visible notification.
    var onError: ((String) -> Void)?
    /// Called when the full pipeline (transcription + post-processing) finishes
    /// and text has been injected. AppDelegate uses this to revert the status
    /// icon from ".transcribing" back to ".idle".
    var onTranscriptionComplete: (() -> Void)?
    /// Called when the daemon fails and we fall back to subprocess mode.
    /// AppDelegate surfaces this in the status bar so the user knows why
    /// transcription was slower than expected (subprocess has ~1.5s vs
    /// daemon's ~0.1s latency).
    var onDaemonError: ((String) -> Void)?
    /// v0.9.1: Called with streaming partial results during capture (PTT and
    /// continuous). The string is the partial transcript so far. TC itself
    /// injects the partial via TextInjector.partialReplace (AX in-place
    /// replacement in the destination app) and fires this callback AFTER
    /// injection — so AppDelegate can update the menu bar label if it wants.
    /// No-op in apps that don't expose kAXSelectedTextRange for write
    /// (graceful degradation).
    var onPartialResult: ((String) -> Void)?

    /// True when the daemon failed and we are currently falling back to the
    /// subprocess engine. Used to defer onTranscriptionComplete until the
    /// final transcription attempt (subprocess) finishes — otherwise the
    /// daemon's failed callback would clear the transcribing state before
    /// the subprocess result arrives, leaving the icon stuck at idle.
    private var isFallingBack = false

    // Audio engine + tap
    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// FIX-6: Cache the last input format so we only re-create the converter
    /// when the mic's format actually changes (e.g. user switched input device).
    /// Converter init is non-trivial (format negotiation) and the input format
    /// from a given mic doesn't change between sessions.
    private var lastInputFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    // WAV file writer. A class so deinit fires when the session ends OR
    // TranscriptionController is deallocated (the crash path). Without this,
    // a crash between startCapture() and stopCapture()/cancelCapture() leaves
    // an orphaned audio file in ~/Library/Caches/.
    private final class WAVWriter {
        let file: AVAudioFile
        let url: URL

        init(file: AVAudioFile, url: URL) {
            self.file = file
            self.url = url
        }

        /// Called on normal session end (stopCapture / cancelCapture) — only
        /// deletes if the file still exists (i.e. processAndInject didn't run
        /// and hasn't already cleaned up).
        func deleteIfExists() {
            try? FileManager.default.removeItem(at: url)
            wfLogD("[WF:TC] deleted temp WAV: \(url.lastPathComponent)")
        }

        deinit {
            // Crash cleanup: if deinit fires and the file still exists, the
            // process crashed mid-session. Delete it.
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                wfLogD("[WF:TC] crash-cleanup deleted: \(url.lastPathComponent)")
            }
        }
    }

    private var wavWriter: WAVWriter?

    // Re-entry guard
    private var isCapturing = false

    // Engine mode (subprocess vs daemon). Read at startCapture time so a
    // menu change takes effect on the next hold.
    private var engine: TranscriptionEngine { EngineConfig.current() }

    // Daemon client (only used when engine == .daemon)
    private let daemon = TranscriptionDaemon()

    // Path to the Python transcribe wrapper (subprocess mode)
    private let transcribePath = "/Users/mih/.local/bin/wf-transcribe"

    // Post-processing
    private let fillerCleaner = FillerWordCleaner()
    private let grammarCorrector = GrammarCorrector()
    private let textInjector = TextInjector()

    // Per-capture mic energy diagnostic. Reports "MIC INPUT SILENT" if
    // peak RMS stayed below the speech threshold — the classic symptom
    // of a Bluetooth headset stuck in A2DP (output-only) mode. Reset
    // at startCapture, observed per-buffer in convertAndWriteToWav,
    // reported at stopCapture / cancelCapture.
    private let micEnergy = MicEnergyTracker()

    // v0.9.1: streaming partials during capture (PTT + continuous).
    // Cumulative byte offset of the WAV file so we can send partial
    // transcriptions (reading only up to the current write position).
    // 16kHz mono 16-bit = 32000 bytes/second + 44-byte WAV header.
    private var wavByteOffset: Int = 0
    private var partialFlushTimer: Timer?
    /// True while partials have started landing in the destination app.
    /// On commit, the final injection needs to know whether to *append* to
    /// the existing partial or *replace* from the start. We use this to
    /// decide which pasteboard+Cmd+V variant to call.
    private var hasInjectedPartial = false

    // MARK: - Public API

    func startCapture() {
        guard !isCapturing else {
            wfLog("[WF:TC] startCapture called while already capturing — ignored")
            return
        }
        wfLog("[WF:TC] startCapture")

        do {
            try setupAudioEngine()
            try openWavFile()
            isCapturing = true
            // Reset the per-capture energy tracker so reportAndReset()
            // at the end only sees THIS session's buffers.
            micEnergy.reset()
            // v0.9.1: reset streaming partial state and start periodic flush.
            // Every 1.0s during capture, we send the current WAV byte offset
            // to the daemon and surface partial results to TextInjector.partialReplace
            // (AX in-place replacement in the destination app). Cadence is
            // read from StreamingConfig so it can be changed at runtime.
            wavByteOffset = 44  // start after WAV header
            hasInjectedPartial = false
            partialFlushTimer?.invalidate()
            let cadence = StreamingConfig.currentCadence().seconds
            partialFlushTimer = Timer.scheduledTimer(
                withTimeInterval: cadence, repeats: true
            ) { [weak self] _ in
                self?.sendPartialTranscription()
            }
            wfLog("[WF:TC] capture started OK — writing to \(wavWriter?.url.path ?? "?")")
        } catch {
            wfLog("[WF:TC] startCapture error: \(error)")
            let msg = (error as NSError).localizedDescription
            teardownAudio()
            closeWavFile()
            DispatchQueue.main.async { [weak self] in
                self?.onError?(msg)
            }
        }
    }

    func stopCapture() {
        guard isCapturing else {
            wfLog("[WF:TC] stopCapture called while not capturing — ignored")
            return
        }
        isCapturing = false
        wfLog("[WF:TC] stopCapture — closing WAV, will transcribe")
        // v0.9.1: stop the partial flush timer — final transcription runs
        // synchronously in transcribe(). Partials were advisory only.
        partialFlushTimer?.invalidate()
        partialFlushTimer = nil

        // Report mic energy for this session BEFORE tearing down the
        // audio engine. If the user reports "empty transcripts",
        // this is the first place to look — silent input means the
        // recognizer had nothing to work with.
        micEnergy.reportAndReset()

        // Stop the engine and close the file so the WAV is fully flushed.
        // IMPORTANT: capture the URL BEFORE closing — the async transcription
        // task needs it after wavWriter is gone (wavWriter is a class-bound
        // struct that won't deinit until the audio file handle is released,
        // which happens at closeWavFile, so URL must be captured before that).
        guard let url = wavWriter?.url else {
            wfLog("[WF:TC] stopCapture — no WAV URL, aborting")
            teardownAudio()
            return
        }
        teardownAudio()
        closeWavFile()

        // Run transcription on a background queue so the UI thread isn't blocked.
        // 1.5s latency is acceptable for push-to-talk.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribe(wavURL: url)
        }
    }

    /// v0.7.3: stop capturing and discard the audio. Used by the
    /// continuous-mode cancel gesture (Esc / Backspace / Forward-Delete).
    /// No transcription, no paste. WAV file is deleted.
    func cancelCapture() {
        guard isCapturing else {
            wfLog("[WF:TC] cancelCapture called while not capturing — ignored")
            return
        }
        isCapturing = false
        wfLog("[WF:TC] cancelCapture — discarding audio, no transcription")
        // v0.9.1: stop the partial flush timer on cancel (no transcription
        // will run).
        partialFlushTimer?.invalidate()
        partialFlushTimer = nil
        // v0.9.1: clear any in-flight partial state. We don't try to
        // delete a partial from the destination app on cancel because
        // the user is explicitly aborting — if they wanted the partial
        // to land they wouldn't have cancelled. But we DO need to clear
        // our tracking so the next startCapture starts clean.
        clearPartialState()

        // Report mic energy for this session even on cancel — the user
        // still benefits from the diagnostic (e.g. "I cancelled because
        // the mic was silent").
        micEnergy.reportAndReset()

        teardownAudio()
        closeWavFile()
        // WAVWriter.deinit handles cleanup — closeWavFile() nils wavWriter,
        // triggering deinit which deletes the file.
    }

    // MARK: - Audio Setup

    private func setupAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        wfLogD("[WF:TC] input format: \(inputFormat.sampleRate)Hz ch=\(inputFormat.channelCount)")

        // Bail with a useful message if there's no input device. This happens
        // on Mac mini (no built-in mic) when no USB/BT mic is connected.
        // The "0.0Hz ch=0" log alone is too cryptic to debug from — surface
        // the real cause.
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            wfLog("[WF:TC] no audio input device available — check System Settings → Sound → Input")
            throw NSError(
                domain: "WF", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "No audio input device. Plug in a USB mic, pair a Bluetooth headset, or use AirPods. Then select it in System Settings → Sound → Input."]
            )
        }

        // FIX-6: Only create a new converter if the input format actually changed
        // (e.g. user switched to a different mic). The format from a given mic
        // is stable across sessions — caching avoids repeated format negotiation.
        if converter == nil || inputFormat != lastInputFormat {
            guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "WF", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter init failed"])
            }
            self.converter = conv
            lastInputFormat = inputFormat
            wfLogD("[WF:TC] created new AVAudioConverter (input: \(inputFormat.sampleRate)Hz ch=\(inputFormat.channelCount))")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndWriteToWav(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        wfLogD("[WF:TC] audioEngine started OK")
    }

    private func convertAndWriteToWav(_ inputBuffer: AVAudioPCMBuffer) {
        guard let conv = converter, let writer = wavWriter else { return }

        // Feed the per-buffer RMS into the energy tracker BEFORE writing
        // to disk. This is the diagnostic signal for the silent-mic bug
        // (BT headset in A2DP mode, mic permission revoked mid-session, etc).
        if let channelData = inputBuffer.floatChannelData?[0] {
            let frames = Int(inputBuffer.frameLength)
            if frames > 0 {
                var sumSquares: Float = 0
                for i in 0..<frames {
                    let sample = channelData[i]
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(frames))
                micEnergy.observe(rms: rms)
            }
        }

        // Convert input → 16kHz mono Float32
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

        var error: NSError?
        var inputConsumed = false

        let status = conv.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            wfLog("[WF:TC] converter error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        if outputBuffer.frameLength > 0 {
            do {
                try writer.file.write(from: outputBuffer)
                // v0.9.1: track cumulative bytes written (for partial flush).
                // Each frame is 2 bytes (16-bit PCM, 1 channel).
                wavByteOffset += Int(outputBuffer.frameLength) * 2
            } catch {
                wfLog("[WF:TC] WAV write error: \(error.localizedDescription)")
            }
        }
    }

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        wfLogD("[WF:TC] audioEngine stopped")
    }

    /// v0.9.1: clear any in-flight partial state. Called on cancel and on
    /// commit-after-inject. Defensive: the injector also clears itself
    /// on delete, but cancel paths can race.
    private func clearPartialState() {
        textInjector.clearPartial()
        hasInjectedPartial = false
    }

    // MARK: - Streaming Partial (v0.9.1)

    /// Called every [cadence]s by the partialFlushTimer during active capture.
    /// Sends the current WAV byte offset to the daemon for a partial
    /// transcription. Results are surfaced via onPartialResult which
    /// AppDelegate forwards to TextInjector.partialReplace (AX in-place).
    private func sendPartialTranscription() {
        guard isCapturing, let url = wavWriter?.url else { return }
        guard StreamingConfig.currentPartialEnabled() else { return }

        let offset = wavByteOffset
        guard offset > 44 else { return }  // need at least some audio past header

        wfLog("[WF:TC] partial flush — offset=\(offset)")

        // Send to daemon on a background queue so we don't block the
        // audio tap callback. The daemon processes ~50-100ms for 1.5s audio.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribePartial(wavURL: url, endByteOffset: offset)
        }
    }

    private func transcribePartial(wavURL: URL, endByteOffset: Int) {
        // Partials only work with the daemon (the subprocess wrapper is
        // synchronous and can't be sliced). In subprocess mode we silently
        // skip — the final transcribe() in stopCapture will still work.
        guard engine == .daemon else { return }

        if !TranscriptionDaemon.isRunning() || !TranscriptionDaemon.isReachable() {
            // No daemon — skip partial, the final stopCapture will
            // transcribe via subprocess.
            return
        }

        do {
            let text = try daemon.sendPartial(wavPath: wavURL.path, endByteOffset: endByteOffset)
            guard !text.isEmpty else { return }
            wfLog("[WF:TC] partial result: \"\(text.prefix(60))\(text.count > 60 ? "..." : "")\")")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // v0.9.1: in-place replace the previous partial in the
                // destination app via AX. Returns false if the app doesn't
                // support AX write (Electron/Chromium) — graceful no-op,
                // the final commit on hotkey release will still work via
                // pasteboard+Cmd+V.
                let replaced = self.textInjector.partialReplace(text: text)
                if !replaced {
                    // No AX support — clear any stale state. The final
                    // injection won't need to delete a partial.
                    self.textInjector.clearPartial()
                }
                self.hasInjectedPartial = self.textInjector.hasPendingPartial
                self.onPartialResult?(text)
            }
        } catch {
            // Don't surface partial errors to the user — they're advisory.
            // The final transcription is the source of truth.
            wfLog("[WF:TC] partial transcribe error: \(error)")
        }
    }

    // MARK: - WAV File

    private func openWavFile() throws {
        // Unique temp file in the proper temp directory (not /tmp directly).
        // Uses FileManager.default.temporaryDirectory which is ~/Library/Caches/
        // on modern macOS — survives crashes unlike raw /tmp.
        // Named with UUID so concurrent sessions don't collide.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,           // 16-bit PCM in the WAV
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.wavWriter = WAVWriter(file: file, url: url)
        wfLogD("[WF:TC] opened WAV for writing: \(url.path)")
    }

    private func closeWavFile() {
        wavWriter = nil
        wfLogD("[WF:TC] closed WAV file")
    }

    // MARK: - Transcription (mlx-whisper)

    private func transcribe(wavURL: URL) {
        wfLog("[WF:TC] transcribe mode=\(engine.shortName) file=\(wavURL.lastPathComponent)")

        switch engine {
        case .daemon:
            transcribeViaDaemon(wavURL: wavURL)
        case .subprocess:
            transcribeViaSubprocess(wavURL: wavURL)
        }
    }

    private func transcribeViaDaemon(wavURL: URL) {
        // If the daemon isn't running, fall back to subprocess (and warn)
        if !TranscriptionDaemon.isRunning() || !TranscriptionDaemon.isReachable() {
            wfLog("[WF:TC] daemon not reachable, falling back to subprocess")
            isFallingBack = true
            DispatchQueue.main.async { [weak self] in
                self?.onDaemonError?("daemon not reachable — using subprocess")
            }
            transcribeViaSubprocess(wavURL: wavURL)
            return
        }

        do {
            let text = try daemon.transcribe(wavPath: wavURL.path)
            wfLog("[WF:TC] daemon returned text=\"\(text.prefix(80))\(text.count > 80 ? "..." : "")\"")
            if text.isEmpty {
                wfLog("[WF:TC] empty transcript — nothing to inject")
                return
            }
            processAndInject(text)
        } catch let error as TranscriptionDaemon.DaemonError {
            let msg = "daemon error: \(error.description)"
            wfLog("[WF:TC] \(msg), falling back to subprocess")
            isFallingBack = true
            DispatchQueue.main.async { [weak self] in
                self?.onDaemonError?(msg)
            }
            transcribeViaSubprocess(wavURL: wavURL)
        } catch {
            let msg = "daemon error: \(error.localizedDescription)"
            wfLog("[WF:TC] \(msg), falling back to subprocess")
            isFallingBack = true
            DispatchQueue.main.async { [weak self] in
                self?.onDaemonError?(msg)
            }
            transcribeViaSubprocess(wavURL: wavURL)
        }
    }

    private func transcribeViaSubprocess(wavURL: URL) {
        wfLog("[WF:TC] launching wf-transcribe on \(wavURL.lastPathComponent)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: transcribePath)
        process.arguments = [wavURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            wfLog("[WF:TC] failed to launch wf-transcribe: \(error.localizedDescription)")
            return
        }

        // Read stdout to data (the transcript). Handle is closed when
        // the process exits, so we can read until EOF.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let transcript = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderrStr.isEmpty {
            // Log the first line of stderr for diagnostics (huggingface_hub
            // progress, deprecation warnings, etc.)
            let firstLine = stderrStr.split(separator: "\n").first.map(String.init) ?? ""
            if !firstLine.isEmpty {
                wfLogD("[WF:TC] wf-transcribe stderr (1st line): \(firstLine)")
            }
        }

        wfLog("[WF:TC] wf-transcribe exit=\(process.terminationStatus) text=\"\(transcript)\"")

        if process.terminationStatus != 0 {
            wfLog("[WF:TC] wf-transcribe failed (exit \(process.terminationStatus))")
            return
        }

        if transcript.isEmpty {
            wfLog("[WF:TC] empty transcript — nothing to inject")
            return
        }

        // Post-process (filler + grammar) and inject at cursor.
        processAndInject(transcript)
    }

    // MARK: - Text Processing

    private func processAndInject(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing to inject — still notify so the icon reverts.
            DispatchQueue.main.async { [weak self] in
                self?.onTranscriptionComplete?()
            }
            return
        }

        // The filler+grammar step output is verbose and is just a sanity
        // check that the post-processing pipeline is doing what we think
        // (e.g. the user reports "my 'um' is still in the output" — turn
        // on WF_DEBUG=1 to see these lines). Keep the start/end markers
        // unconditional so we know the pipeline actually ran.
        let noFillers: String
        if FillerConfig.current() == .standard {
            noFillers = fillerCleaner.clean(trimmed)
            wfLogD("[WF:TC] after filler removal: \"\(noFillers)\"")
        } else {
            noFillers = trimmed
            wfLogD("[WF:TC] filler cleanup disabled — skipping")
        }

        let corrected = grammarCorrector.correct(noFillers)
        wfLogD("[WF:TC] after grammar: \"\(corrected)\"")

        let final = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else {
            // Empty after processing — still notify so the icon reverts.
            DispatchQueue.main.async { [weak self] in
                if !self!.isFallingBack {
                    self?.onTranscriptionComplete?()
                }
            }
            return
        }

        // ALWAYS log the final injection — this is the line that tells
        // you "the dictation pipeline actually produced and injected
        // this text." The single most useful line for support.
        wfLog("[WF:TC] injecting: \"\(final)\"")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // v0.9.3 fix: if a streaming partial was AX-injected in the
            // destination app, remove it before the pasteboard+Cmd+V —
            // otherwise the final text would append AFTER the partial,
            // producing duplicates ("[partial][final]").
            //
            // We only do this when hasPendingPartial == true, which means
            // partials actually landed via AX in this app. In Electron/Chromium
            // apps partials are graceful no-ops (AX write isn't supported) so
            // lastPartialText stays nil, hasPendingPartial is false, and we
            // skip the delete — avoiding the v0.9.1 bug where the AX delete
            // confused Electron input field state and the final text vanished.
            if self.textInjector.hasPendingPartial {
                let removed = self.textInjector.deleteLastPartial()
                wfLog("[WF:TC] removed last partial before final inject: \(removed ? "ok" : "FAILED")")
            }
            self.textInjector.inject(final)
            self.onResult?(final)
            // Only fire if we're NOT mid-fallback — the subprocess handles
            // its own completion callback. After firing, reset the flag.
            if !self.isFallingBack {
                self.onTranscriptionComplete?()
            } else {
                self.isFallingBack = false
            }
        }
    }
}
