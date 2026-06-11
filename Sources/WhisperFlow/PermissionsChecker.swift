import AVFoundation
import Speech
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.whisperflow", category: "PermissionsChecker")

func wfLogP(_ msg: String) { wfLog(msg) }

/// Checks and requests all required permissions for WhisperFlow.
/// Must be called on main thread.
final class PermissionsChecker {

    /// Returns true only if ALL permissions are granted.
    /// On macOS Sequoia with ad-hoc signed builds, the CDHash-based TCC entry
    /// from a prior rebuild won't match the current binary, causing both
    /// AXIsProcessTrusted() and the silent variant to return false even when
    /// Accessibility is visibly enabled in System Settings. This function
    /// detects that stuck state and offers a recovery path.
    func requestAllPermissions(completion: @escaping (Bool) -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        let bundlePath = Bundle.main.bundlePath
        let axAtEntry = AXIsProcessTrusted()
        wfLog("[WF:Perms] entry — bundle=\(bundleID) path=\(bundlePath) AX=\(axAtEntry ? 1 : 0)")
        logger.info("Permission check starting (AX at entry = \(axAtEntry), bundle=\(bundleID))")

        requestMicrophonePermission { [weak self] micGranted in
            wfLog("[WF:Perms] microphone granted = \(micGranted ? 1 : 0)")
            guard micGranted else {
                logger.error("Microphone permission denied")
                completion(false)
                return
            }

            self?.requestSpeechPermission { [weak self] speechGranted in
                wfLog("[WF:Perms] speech granted = \(speechGranted ? 1 : 0)")
                guard speechGranted else {
                    logger.error("Speech recognition permission denied")
                    completion(false)
                    return
                }

                // ── Accessibility check ──────────────────────────────────
                // On Sequoia with ad-hoc signing, a rebuild changes the
                // CDHash, orphaning the TCC entry. We try three strategies:
                //
                //   1. AXIsProcessTrusted()         — authoritative, no dialog
                //   2. prompt:false                 — silent re-evaluation
                //   3. prompt:true                  — forces TCC dialog if
                //                                     entry exists but CDHash
                //                                     is stale; creates new
                //                                     entry if user confirms
                //
                // If prompt:true returns true → permission recovered.
                // If prompt:true returns false → user needs to manually
                // remove + re-add the TCC entry in System Settings.
                // ─────────────────────────────────────────────────────────
                let ax = AXIsProcessTrusted()
                wfLog("[WF:Perms] AX at decision = \(ax ? 1 : 0)")

                if ax {
                    logger.info("Accessibility permission granted ✓")
                    completion(true)
                    return
                }

                // Fallback 1: silent TCC re-evaluation
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
                let axSilent = AXIsProcessTrustedWithOptions(options)
                wfLog("[WF:Perms] AX with prompt:false = \(axSilent ? 1 : 0)")

                if axSilent {
                    logger.info("Accessibility granted (silent check recovered)")
                    completion(true)
                    return
                }

                // Fallback 2: force TCC re-evaluation with prompt.
                // This shows the TCC dialog if the user already granted access
                // but the CDHash mismatch is blocking us. If the user confirms
                // in the dialog, AXIsProcessTrusted() will return true.
                // If they dismiss, it returns false and the app shows the
                // manual fix instructions.
                logger.warning("CDHash stuck state — forcing TCC re-evaluation with prompt")
                wfLog("[WF:Perms] CDHash stuck state — trying prompt:true to trigger TCC dialog")

                let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                let axPrompt = AXIsProcessTrustedWithOptions(promptOptions)
                wfLog("[WF:Perms] AX with prompt:true = \(axPrompt ? 1 : 0)")

                if axPrompt {
                    logger.info("Accessibility granted (TCC re-eval succeeded)")
                    completion(true)
                } else {
                    // All checks failed — CDHash mismatch requires manual fix.
                    logger.error("Accessibility permission not granted (CDHash mismatch)")
                    wfLog("[WF:Perms] AX false after all fallbacks — CDHash mismatch requires manual TCC fix")
                    completion(false)
                }
            }
        }
    }

    // MARK: - Individual Permissions

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func requestSpeechPermission(completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}