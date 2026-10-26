import AppKit
import SwiftUI

// MARK: - Settings Window Controller

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperFlow Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 500)

        let contentView = SettingsView()
        window.contentView = NSHostingView(rootView: contentView)

        self.init(window: window)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI Settings View (Phase C)
//
// Single Form, five sections, ordered to mirror the menu-bar dropdown
// (daily basics first, advanced last). Every setting appears exactly
// once. Wiring only — each control reads/writes the same UserDefaults
// key (or config file) the menu path uses, so toggle states persist
// across relaunch via the existing pattern.

struct SettingsView: View {
    // FIX-O3: use @AppStorage so changes from the menu bar / another path
    // reflect in the window automatically. Was @State + manual read at view
    // creation — would show stale values if the menu was used to flip a
    // setting and then Settings was opened without a tab switch.

    // Audio & Hotkey
    @AppStorage("WFHotkeyPreset") private var hotkey: HotkeyPreset = HotkeyConfig.current()

    // Transcription & Model
    @AppStorage("WFTranscriptionEngine") private var engine: TranscriptionEngine = EngineConfig.current()

    // Cleanup & Dictionary
    @AppStorage("WFGrammarMode") private var grammar: GrammarMode = GrammarConfig.current()
    @AppStorage("WFFillerMode") private var filler: FillerMode = FillerConfig.current()

    // LLM polish (Phase B, opt-in — default off)
    @AppStorage("WFPolishLLMEnabled") private var llmEnabled: Bool = false
    @AppStorage("WFPolishLLMModel") private var llmModel: String = LLMPolishConfig.defaultModel
    @AppStorage("WFPolishLLMTimeout") private var llmTimeout: Double = LLMPolishConfig.defaultTimeout

    // Advanced
    @AppStorage("WFStreamingCadence") private var cadence: CadenceMode = StreamingConfig.currentCadence()
    @AppStorage("WFStreamingPartialEnabled") private var partialEnabled: Bool = StreamingConfig.currentPartialEnabled()
    @AppStorage("WFCopyToClipboard") private var copyToClipboard: Bool = false

    // Model is read from ~/.config/whisperflow/model (a FILE, not UserDefaults),
    // so @AppStorage doesn't fit. Keep @State + manual sync.
    @State private var model: WhisperModel = ModelConfig.currentModel()

    // User dictionary (UserDefaults JSON via DictionaryConfig) — edited
    // as a sorted entry list with add/remove/reset.
    @State private var dictEntries: [(wrong: String, right: String)] = []
    @State private var newWrong: String = ""
    @State private var newRight: String = ""

    var body: some View {
        ScrollView {
            Form {
                audioHotkeySection
                transcriptionModelSection
                cleanupDictionarySection
                llmPolishSection
                advancedSection
            }
            .padding(20)
        }
        .frame(width: 600, height: 700)
        .onAppear {
            // Sync file-backed state on open (menu may have changed it).
            model = ModelConfig.currentModel()
            reloadDictionary()
        }
    }

    // MARK: - Audio & Hotkey

    private var audioHotkeySection: some View {
        Section("Audio & Hotkey") {
            Picker("Activation hotkey:", selection: $hotkey) {
                ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .onChange(of: hotkey) { newValue in  // N2: keep deprecated single-param form until deployment target ≥ macOS 14
                HotkeyConfig.set(newValue)
            }

            explainer("Hold the hotkey to record, release to inject text.")
            explainer("Ctrl+Shift is the default — works on all keyboard layouts.")
            explainer("Ctrl+Option may conflict with input-source switching on non-Polish layouts.")
        }
    }

    // MARK: - Transcription & Model

    private var transcriptionModelSection: some View {
        Section("Transcription & Model") {
            Picker("Transcription engine:", selection: $engine) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { eng in
                    Text(eng.displayName).tag(eng)
                }
            }
            .onChange(of: engine) { newValue in  // N2: see above — needs macOS 14 target
                EngineConfig.set(newValue)
            }

            explainer("Subprocess: launches Python per transcription. ~1.5s latency, 0 idle RAM.")
            explainer("Daemon: keeps model in RAM. ~50-100ms latency, ~1GB idle cost.")

            Picker("Whisper model:", selection: $model) {
                ForEach(WhisperModel.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .onChange(of: model) { newValue in  // N2: see above — needs macOS 14 target
                ModelConfig.setModel(newValue)
            }

            explainer("Model used for transcription. Takes effect on the next recording.")
        }
    }

    // MARK: - Cleanup & Dictionary

    private var cleanupDictionarySection: some View {
        Section("Cleanup & Dictionary") {
            Picker("Auto-punctuation:", selection: $grammar) {
                ForEach(GrammarMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: grammar) { newValue in  // N2: see above — needs macOS 14 target
                GrammarConfig.set(newValue)
            }

            explainer("Auto-punctuate: adds trailing period if needed, capitalizes sentence starts.")
            explainer("Raw: preserves your punctuation verbatim. Use for code/commands.")

            Picker("Filler cleanup:", selection: $filler) {
                ForEach(FillerMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: filler) { newValue in  // N2: see above — needs macOS 14 target
                FillerConfig.set(newValue)
            }

            explainer("Standard: removes uh, um, like, I think, you know, etc.")
            explainer("Disabled: keeps all filler words verbatim.")

            Text("Word replacements:")
            explainer("Spoken form on the left is always replaced with the exact text on the right.")

            ForEach(dictEntries, id: \.wrong) { entry in
                HStack {
                    Text(entry.wrong)
                    Text("→")
                        .foregroundColor(.secondary)
                    Text(entry.right)
                    Spacer()
                    Button("Remove") {
                        DictionaryConfig.remove(entry.wrong)
                        reloadDictionary()
                    }
                    .buttonStyle(.link)
                }
            }

            HStack {
                TextField("heard as…", text: $newWrong)
                TextField("replace with…", text: $newRight)
                Button("Add") {
                    guard DictionaryConfig.add(wrong: newWrong, right: newRight) else { return }
                    newWrong = ""
                    newRight = ""
                    reloadDictionary()
                }
                .disabled(newWrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newRight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Reset to defaults") {
                DictionaryConfig.resetToSeeds()
                reloadDictionary()
            }
        }
    }

    // MARK: - LLM Polish (Optional, default off)

    private var llmPolishSection: some View {
        Section("LLM Polish (Optional, default off)") {
            Toggle("Enable LLM polish (local Ollama)", isOn: $llmEnabled)
                .onChange(of: llmEnabled) { newValue in  // N2: see above — needs macOS 14 target
                    LLMPolishConfig.setEnabled(newValue)
                }

            explainer("Off (default): Phase A pipeline only. On: the raw transcript is sent to local Ollama after Phase A; any failure falls back silently.")

            TextField("Model:", text: $llmModel)
                .onChange(of: llmModel) { newValue in
                    LLMPolishConfig.setModel(newValue)
                }
                .disabled(!llmEnabled)

            Stepper("Timeout: \(Int(llmTimeout))s", value: $llmTimeout, in: 5...60, step: 5)
                .onChange(of: llmTimeout) { newValue in
                    LLMPolishConfig.setTimeout(newValue)
                }
                .disabled(!llmEnabled)

            explainer("Localhost only — no API keys, no network beyond this Mac.")
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section("Advanced") {
            Picker("Partial cadence:", selection: $cadence) {
                ForEach(CadenceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: cadence) { newValue in  // N2: see above — needs macOS 14 target
                StreamingConfig.setCadence(newValue)
            }

            explainer("How often to update in-place text during dictation.")

            Toggle("Show partial text in-place", isOn: $partialEnabled)
                .onChange(of: partialEnabled) { newValue in  // N2: see above — needs macOS 14 target
                    StreamingConfig.setPartialEnabled(newValue)
                }

            explainer("When off, only the final text is inserted on commit.")

            Toggle("Copy transcription to clipboard", isOn: $copyToClipboard)
                .onChange(of: copyToClipboard) { newValue in
                    ClipboardConfig.setEnabled(newValue)
                }

            explainer("When on, the transcribed text stays in the clipboard after injection (pasteboard+Cmd+V). When off, the clipboard is never touched.")
        }
    }

    // MARK: - Helpers

    private func explainer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private func reloadDictionary() {
        dictEntries = DictionaryConfig.entries()
            .sorted(by: { $0.key < $1.key })
            .map { (wrong: $0.key, right: $0.value) }
    }
}
