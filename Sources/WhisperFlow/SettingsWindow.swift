import AppKit
import SwiftUI

// MARK: - Settings Window Controller

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperFlow Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = SettingsView()
        window.contentView = NSHostingView(rootView: contentView)

        self.init(window: window)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI Settings View

struct SettingsView: View {
    @State private var cadence: CadenceMode     = StreamingConfig.currentCadence()
    @State private var partialEnabled: Bool    = StreamingConfig.currentPartialEnabled()
    @State private var hotkey: HotkeyPreset     = HotkeyConfig.current()
    @State private var engine: TranscriptionEngine = EngineConfig.current()
    @State private var grammar: GrammarMode     = GrammarConfig.current()
    @State private var filler: FillerMode      = FillerConfig.current()

    var body: some View {
        TabView {
            streamingTab
                .tabItem { Text("Streaming") }
                .tag(0)

            hotkeyTab
                .tabItem { Text("Hotkey") }
                .tag(1)

            engineTab
                .tabItem { Text("Engine") }
                .tag(2)

            grammarTab
                .tabItem { Text("Grammar") }
                .tag(3)

            fillerTab
                .tabItem { Text("Filler Words") }
                .tag(4)
        }
        .padding(20)
        .frame(width: 480, height: 320)
    }

    // MARK: - Streaming

    var streamingTab: some View {
        Form {
            Section {
                Picker("Partial cadence:", selection: $cadence) {
                    ForEach(CadenceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: cadence) { newValue in
                    StreamingConfig.setCadence(newValue)
                }

                Text("How often to update in-place text during dictation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Show partial text in-place", isOn: $partialEnabled)
                    .onChange(of: partialEnabled) { newValue in
                        StreamingConfig.setPartialEnabled(newValue)
                    }

                Text("When off, only the final text is inserted on commit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Hotkey

    var hotkeyTab: some View {
        Form {
            Section {
                Picker("Activation hotkey:", selection: $hotkey) {
                    ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: hotkey) { newValue in
                    HotkeyConfig.set(newValue)
                }

                Text("Hold the hotkey to record, release to inject text.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Text("Ctrl+Shift is the default — works on all keyboard layouts.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Ctrl+Option may conflict with input-source switching on non-Polish layouts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Engine

    var engineTab: some View {
        Form {
            Section {
                Picker("Transcription engine:", selection: $engine) {
                    ForEach(TranscriptionEngine.allCases, id: \.self) { eng in
                        Text(eng.displayName).tag(eng)
                    }
                }
                .onChange(of: engine) { newValue in
                    EngineConfig.set(newValue)
                }
            }

            Section {
                Text("Subprocess: launches Python per transcription. ~1.5s latency, 0 idle RAM.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Daemon: keeps model in RAM. ~50-100ms latency, ~1GB idle cost.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Grammar

    var grammarTab: some View {
        Form {
            Section {
                Picker("Grammar mode:", selection: $grammar) {
                    ForEach(GrammarMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: grammar) { newValue in
                    GrammarConfig.set(newValue)
                }
            }

            Section {
                Text("Auto-punctuate: adds trailing period if needed, capitalizes sentence starts.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Raw: preserves your punctuation verbatim. Use for code/commands.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Filler Words

    var fillerTab: some View {
        Form {
            Section {
                Picker("Filler cleanup:", selection: $filler) {
                    ForEach(FillerMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: filler) { newValue in
                    FillerConfig.set(newValue)
                }
            }

            Section {
                Text("Standard: removes uh, um, like, I think, you know, etc.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Disabled: keeps all filler words verbatim.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }
}
