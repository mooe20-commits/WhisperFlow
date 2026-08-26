import AppKit
import AVFoundation
import SwiftUI

// MARK: - First-Run Onboarding Window
//
// v0.9.7: replaces the alert-driven permission flow. Shows a checklist of
// what WhisperFlow needs (Microphone, Accessibility, Python backend, model)
// with live status, so a new user can see exactly what's missing and why.

final class OnboardingWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WhisperFlow"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView())
        self.init(window: window)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RequirementRow: View {
    let title: String
    let detail: String
    let state: ReqState

    enum ReqState { case ok, pending, actionNeeded }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch state {
        case .ok: return "checkmark.circle.fill"
        case .pending: return "clock"
        case .actionNeeded: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .ok: return .green
        case .pending: return .secondary
        case .actionNeeded: return .orange
        }
    }
}

struct OnboardingView: View {
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axOK = AXIsProcessTrusted()
    @State private var wrapperFound = false
    @State private var checkedWrapper = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WhisperFlow")
                .font(.largeTitle.bold())
            Text("Local push-to-talk dictation. Hold the hotkey, speak, release — text appears at your cursor. Everything runs on this Mac; nothing leaves it.")
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            RequirementRow(
                title: "Microphone access",
                detail: micOK ? "Granted" : "Required to record audio",
                state: micOK ? .ok : .actionNeeded
            )
            RequirementRow(
                title: "Accessibility",
                detail: axOK ? "Granted" : "Required for the global hotkey and typing text at your cursor",
                state: axOK ? .ok : .actionNeeded
            )
            RequirementRow(
                title: "Transcription backend (wf-transcribe)",
                detail: !checkedWrapper
                    ? "Checking…"
                    : wrapperFound
                        ? "Found in ~/.local/bin"
                        : "Missing — run the setup script or install mlx-whisper",
                state: !checkedWrapper ? .pending : (wrapperFound ? .ok : .actionNeeded)
            )

            Divider()

            if allGood {
                Label("All set! Click the mic icon in the menu bar and hold \(HotkeyConfig.current().displayName) to dictate.",
                      systemImage: "sparkles")
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !micOK {
                        Button("Grant Microphone Access") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                    if !axOK {
                        Button("Grant Accessibility") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    if !wrapperFound && checkedWrapper {
                        Button("Re-check") { refresh() }
                    }
                }
            }

            Spacer()
            Text("First transcription downloads the whisper model (~0.8–1.4 GB) automatically. Subsequent runs are instant.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .onAppear(perform: refresh)
    }

    private var allGood: Bool {
        micOK && axOK && wrapperFound
    }

    private func refresh() {
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axOK = AXIsProcessTrusted()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/wf-transcribe")
        wrapperFound = FileManager.default.isExecutableFile(atPath: url.path)
        checkedWrapper = true
    }
}
