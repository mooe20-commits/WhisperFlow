import Foundation

/// Reads/writes the user's chosen Whisper model.
///
/// The config file lives at `~/.config/whisperflow/model` and contains a
/// single line: the HuggingFace model repo id (e.g.
/// `mlx-community/whisper-base.en-mlx`).
///
/// The Python `wf-transcribe` wrapper and `wf-transcribe-daemon` read this
/// file when the `WF_WHISPER_MODEL` env var isn't set, so model changes
/// from the menu take effect on the next transcription (or on the next
/// reload for the daemon).
///
/// tiny.en was removed because its WER on accented English was too high to
/// be useful. We keep base.en (~3s, balanced) and small.en (~6s, best
/// accuracy) as the two options.
enum WhisperModel: String, CaseIterable {
    case base  = "mlx-community/whisper-base.en-mlx"
    case small = "mlx-community/whisper-small.en-mlx"

    /// Human-readable label for the menu
    var displayName: String {
        switch self {
        case .base:  return "base.en  (balanced, ~80ms daemon / 1.5s subprocess, ~810MB)"
        case .small: return "small.en (most accurate, ~80ms daemon / 2.2s subprocess, ~1.4GB)"
        }
    }

    /// Short label for the menu (just the model name)
    var shortName: String {
        switch self {
        case .base:  return "base.en"
        case .small: return "small.en"
        }
    }

    /// Default model when no config exists
    static var defaultModel: WhisperModel { .base }
}

enum ModelConfig {
    private static let configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/whisperflow", isDirectory: true)
    }()

    private static let configFile: URL = configDir.appendingPathComponent("model")

    /// Read the currently selected model. Returns the default if no config
    /// exists, or if the config contains a removed model (e.g. legacy
    /// `tiny.en` from a previous version).
    static func currentModel() -> WhisperModel {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else {
            return .defaultModel
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // If config points to a removed model, fall back to default
        return WhisperModel(rawValue: trimmed) ?? .defaultModel
    }

    /// Write the chosen model to the config file. Creates the directory
    /// if it doesn't exist. Returns true on success.
    @discardableResult
    static func setModel(_ model: WhisperModel) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: configDir,
                withIntermediateDirectories: true
            )
            try model.rawValue.write(
                to: configFile,
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            wfLog("[WF:Model] failed to write config: \(error.localizedDescription)")
            return false
        }
    }
}
