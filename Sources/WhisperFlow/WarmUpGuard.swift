import Foundation

/// Warm-up guard (v0.9.8.1): AVAudioEngine raises an ObjC NSException (not a
/// Swift error) when a second engine tries to claim the input node while
/// another process/engine holds it — e.g. our own transcription daemon.
/// NSExceptions can't be caught by Swift do/catch and terminate the app.
///
/// Root-cause avoidance instead of catching: only run the BT warm-up engine
/// when nothing else is holding the mic. The daemon performs its own audio
/// init, and the on-demand path in setupAudioEngine() handles route
/// negotiation at capture time regardless.
enum WarmUpGuard {
    /// True if another WhisperFlow component likely holds the microphone.
    static func micIsBusy() -> Bool {
        // Daemon mode + daemon alive → daemon owns the input.
        EngineConfig.current() == .daemon && TranscriptionDaemon.isRunning()
    }
}
