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
/// v0.9.9: three models — base.en (fastest), small.en (balanced default),
/// and medium-mlx-4bit (most accurate; note: emits no periods/commas).
/// tiny.en was removed because its WER on accented English was too high.
enum WhisperModel: String, CaseIterable {
    case base   = "mlx-community/whisper-base.en-mlx"
    case small  = "mlx-community/whisper-small.en-mlx"
    case medium = "mlx-community/whisper-medium-mlx-4bit"

    /// Human-readable label for the menu.
    /// v0.9.9: latency figures updated from real daemon measurements —
    /// MLX on Apple Silicon transcribes far faster than realtime, so all
    /// models are sub-second for typical utterances. The old "1.5–2.2s"
    /// figures described subprocess cold-start (model load per call), not
    /// transcription itself.
    var displayName: String {
        switch self {
        case .base:   return "base.en   (fastest, ~470 MB)"
        case .small:  return "small.en   (balanced, ~1.4 GB RAM)"
        case .medium: return "medium     (most accurate, ~1.5 GB RAM, no auto-punctuation)"
        }
    }

    /// Short label for the menu (just the model name)
    var shortName: String {
        switch self {
        case .base:   return "base.en"
        case .small:  return "small.en"
        case .medium: return "medium"
        }
    }

    /// Approximate download size for first-run messaging.
    var approxDownloadMB: Int {
        switch self {
        case .base:   return 200
        case .small:  return 460
        case .medium: return 950
        }
    }

    /// Default model when no config exists
    static var defaultModel: WhisperModel { .small }

    /// v0.9.8: whether the model weights are already present in the local
    /// HuggingFace cache. Used by the onboarding window to show "model
    /// ready" vs "will download ~X MB on first use".
    var isDownloaded: Bool {
        ModelCache.isModelCached(repoId: rawValue)
    }
}

enum ModelCache {
    private static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// huggingface_hub caches a repo at
    /// ~/.cache/huggingface/hub/models--<org>--<name>/snapshots/<sha>/
    static func isModelCached(repoId: String) -> Bool {
        let safe = repoId.replacingOccurrences(of: "/", with: "--")
        let dir = cacheRoot.appendingPathComponent("models--\(safe)", isDirectory: true)
        let snapshots = dir.appendingPathComponent("snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else {
            return false
        }
        // Any snapshot dir containing at least one .safetensors/.gguf file
        // counts as cached (weights present).
        for entry in entries where !entry.hasPrefix(".") {
            let snap = snapshots.appendingPathComponent(entry)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: snap.path),
               files.contains(where: { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") || $0.hasSuffix(".npz") }) {
                return true
            }
        }
        return false
    }
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
