import Foundation
import OSLog

private let logger = Logger(subsystem: "com.whisperflow", category: "MicEnergy")

/// Tracks mic input energy across a capture session and flags silent input.
///
/// ## Why
///
/// macOS may report a working input device that the audio engine happily
/// delivers "buffers" from — but the buffer data is silent (RMS ≈ 0).
/// This happens with some Bluetooth headsets stuck in A2DP mode (which is
/// output-only) when the OS hasn't successfully switched to HFP for the
/// mic. The system audio path is connected, but no real audio flows.
///
/// The recognizer sees the silent buffers and returns error 1110
/// ("No speech detected"), which looks like a STT bug but is really
/// an audio-routing issue.
///
/// This tracker observes per-buffer RMS and at end-of-session reports:
/// - "Mic input flowing — peak X" if energy crossed the speech threshold
/// - "⚠ Mic input silent — peak X" if max RMS stayed below threshold
final class MicEnergyTracker {
    /// RMS below this is considered silence. ≈ -50 dBFS.
    /// Real close-mic speech is typically 0.05 - 0.3 RMS.
    var silenceThreshold: Float = 0.005

    private var bufferCount: Int = 0
    private var sumRMS: Float = 0
    private var maxRMS: Float = 0
    private var aboveThresholdCount: Int = 0

    func observe(rms: Float) {
        bufferCount += 1
        sumRMS += rms
        if rms > maxRMS { maxRMS = rms }
        if rms > silenceThreshold { aboveThresholdCount += 1 }
    }

    /// Reset all counters to zero. Call this at the START of a capture
    /// session (the existing `reportAndReset()` also resets, so you only
    /// need this if you want to reset mid-session without logging).
    func reset() {
        bufferCount = 0
        sumRMS = 0
        maxRMS = 0
        aboveThresholdCount = 0
    }

    func reportAndReset() {
        guard bufferCount > 0 else {
            // Debug-only: fires on every cancel-with-no-audio or zero-
            // length recording, which is expected when the user just
            // taps-and-releases without speaking.
            wfLogD("[WF:Mic] no buffers observed")
            reset()
            return
        }
        let avgRMS = sumRMS / Float(bufferCount)
        let isSilent = maxRMS < silenceThreshold
        let dBPeak = 20 * log10(max(maxRMS, 0.00001))

        if isSilent {
            wfLog("[WF:Mic] ⚠ MIC INPUT SILENT — peak=\(String(format: "%.4f", maxRMS)) (\(String(format: "%.1f", dBPeak))dB), avg=\(String(format: "%.4f", avgRMS)), buffers=\(bufferCount)")
            wfLog("[WF:Mic] → BT headset may be in A2DP (output-only) mode. Check System Settings → Bluetooth → WI-C100 → Audio Mode = HFP/Headset. Or use a different mic.")
        } else {
            wfLog("[WF:Mic] ✓ mic input flowing — peak=\(String(format: "%.4f", maxRMS)) (\(String(format: "%.1f", dBPeak))dB), avg=\(String(format: "%.4f", avgRMS)), above-threshold buffers: \(aboveThresholdCount)/\(bufferCount)")
        }

        // Reset for next session
        reset()
    }
}
