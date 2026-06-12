import AppKit

/// v0.9 floating non-activating panel that shows streaming partial
/// transcription near the cursor during PTT and continuous recording.
///
/// **Decoupled from the destination app.** The panel is purely advisory
/// visual feedback — it never touches the destination text field. The
/// final injection at commit uses the proven pasteboard+Cmd+V path
/// (`TextInjector`), unchanged from v0.7.3.2.
///
/// This replaces the v0.8 marker-based in-place replacement strategy,
/// which was unfixable in Electron/Chromium apps (Telegram, Slack, VSCode,
/// Discord) that don't expose `kAXSelectedTextRange` for write.
///
/// Design rationale:
///   - `.nonactivatingPanel`: never steals focus from the destination app
///   - `level = .floating`: stays above normal windows, below modal alerts
///   - `.canJoinAllSpaces, .fullScreenAuxiliary`: visible in fullscreen apps
///   - Anchored at first show, not live cursor tracking (less jitter, matches
///     what commercial tools like Wispr Flow / MacWhisper do)
///   - 20fps throttle on text updates to avoid flicker if daemon returns
///     partials faster than we render
final class StreamingPreviewPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private let visualEffectView: NSVisualEffectView
    private let containerView: NSView
    private var isShown = false
    private var anchorPoint: NSPoint = .zero  // mouse position at first show
    private var lastUpdateTime: Date = .distantPast

    // Tunables
    private let panelWidth: CGFloat = 480
    private let panelMinHeight: CGFloat = 44
    private let panelMaxHeight: CGFloat = 120
    private let panelPadding: CGFloat = 12
    private let cursorOffset: NSPoint = NSPoint(x: 24, y: -100)  // down-right of cursor
    private let textFontSize: CGFloat = 14
    private let throttledUpdateInterval: TimeInterval = 0.05  // 20fps max

    init() {
        // Panel — nonactivating so it doesn't steal focus from the
        // destination app where the user is actually typing.
        let contentRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelMinHeight)
        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        // Container view (rounded corners via layer)
        let contentView = NSView(frame: contentRect)
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 10
        contentView.layer?.masksToBounds = true

        // Visual effect view (rounded translucent background)
        visualEffectView = NSVisualEffectView(frame: contentRect)
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.autoresizingMask = [.width, .height]
        contentView.addSubview(visualEffectView)

        // Label
        label = NSTextField(frame: NSRect(
            x: panelPadding, y: panelPadding,
            width: panelWidth - 2 * panelPadding,
            height: panelMinHeight - 2 * panelPadding
        ))
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.textColor = .labelColor
        label.font = NSFont.systemFont(ofSize: textFontSize, weight: .regular)
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.maximumNumberOfLines = 4
        label.autoresizingMask = [.width]
        contentView.addSubview(label)

        panel.contentView = contentView
        containerView = contentView
    }

    deinit {
        // Defensive: if the app is killed while the panel is up, ordering
        // out here prevents a stale panel on next launch.
        panel.orderOut(nil)
    }

    /// Show the panel near the cursor. Called on first partial.
    /// Anchor point is captured here — panel does NOT track the cursor
    /// after first show (less jitter, simpler).
    func showNearCursor(text: String) {
        if isShown {
            update(text: text)
            return
        }
        anchorPoint = NSEvent.mouseLocation
        positionAtAnchor()
        label.stringValue = text
        sizeToFit(text: text)
        panel.orderFrontRegardless()
        isShown = true
    }

    /// Update the panel text. Throttled to 20fps to avoid flicker.
    func update(text: String) {
        guard isShown else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= throttledUpdateInterval else { return }
        lastUpdateTime = now
        label.stringValue = text
        sizeToFit(text: text)
    }

    /// Hide the panel. Called on commit, cancel, or transcription complete.
    func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        isShown = false
        lastUpdateTime = .distantPast
    }

    // MARK: - Layout

    private func positionAtAnchor() {
        // anchorPoint is in screen coordinates (bottom-left origin)
        // NSPanel frame is in screen coordinates (bottom-left origin) too
        let x = anchorPoint.x + cursorOffset.x
        let y = anchorPoint.y + cursorOffset.y

        // Clamp to screen bounds so the panel doesn't go off-screen on edge
        // of monitor (e.g. user is typing in bottom-right corner).
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let clampedX = min(max(x, screenFrame.minX), screenFrame.maxX - panelSize.width)
        let clampedY = min(max(y, screenFrame.minY), screenFrame.maxY - panelSize.height)

        panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    private func sizeToFit(text: String) {
        // Calculate required height for the text (capped at panelMaxHeight)
        let textWidth = panelWidth - 2 * panelPadding
        let attributedString = NSAttributedString(
            string: text.isEmpty ? " " : text,  // placeholder for empty
            attributes: [.font: label.font as Any]
        )
        let textRect = attributedString.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textHeight = ceil(textRect.height)
        let newHeight = min(
            max(panelMinHeight, textHeight + 2 * panelPadding),
            panelMaxHeight
        )
        if abs(panel.frame.height - newHeight) > 1 {
            panel.setContentSize(NSSize(width: panelWidth, height: newHeight))
            // The label is autoresizing — no manual re-layout needed
        }
    }
}
