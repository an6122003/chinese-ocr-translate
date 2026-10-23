import AppKit
import HanziKit
import SwiftUI

/// A floating, non-activating panel: it takes keyboard input (esc, space, ⌘E…) without stealing focus
/// from the app you're reading in, and stays above full-screen apps.
final class ResultPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// ← / → (−1 / +1) to move between words.
    var onArrow: ((Int) -> Void)?
    /// ⌘E: edit the recognized text.
    var onEdit: (() -> Void)?

    init(width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .utilityWindow],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 360, height: 120)
        maxSize = NSSize(width: 900, height: 4000)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Esc and the arrow keys are handled here, before text views get them (NSTextView turns Esc into
    /// "complete:"). While an input method is composing (e.g. typing pinyin with the Pinyin IME) keys pass through.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !isComposingText {
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch Int(event.keyCode) {
            case 53 where plain:                            // esc
                onCancel?()
                return
            case 123 where plain && !isEditingText:         // ←
                onArrow?(-1)
                return
            case 124 where plain && !isEditingText:         // →
                onArrow?(1)
                return
            case 14 where event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
                && !isEditingText:                          // ⌘E
                onEdit?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    private var isEditingText: Bool { firstResponder is NSTextView }

    private var isComposingText: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}

/// Shows lookups in floating panels next to what you selected, sized to their content.
final class PanelController: NSObject, NSWindowDelegate {
    private struct Entry {
        let panel: ResultPanel
        let model: LookupModel
        var anchor: Anchor
    }

    /// Which edge of the panel stays put while its height changes.
    private enum Anchor {
        case top(CGFloat)     // panel hangs below this y (grows downward)
        case bottom(CGFloat)  // panel sits above this y (grows upward)
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var clickMonitor: Any?
    /// True while HanLens itself moves/resizes a panel, so `windowDidMove` doesn't mistake it for a user drag.
    private var isAdjustingFrame = false
    /// Latest content height per panel, applied once per run-loop pass (outside SwiftUI's layout).
    private var pendingHeights: [ObjectIdentifier: CGFloat] = [:]
    private let settings: AppSettings
    var onCaptureAgain: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    /// Shows `model` near `selection` (global screen coordinates), or near the mouse when nil.
    func show(_ model: LookupModel, near selection: CGRect?) {
        closeUnpinned()
        let width = CGFloat(settings.panelWidth)
        let panel = ResultPanel(width: width)
        panel.delegate = self
        let screen = screen(for: selection)
        let visible = screen.visibleFrame
        let maxHeight = visible.height * 0.82

        let id = ObjectIdentifier(panel)
        let root = ResultView(
            model: model,
            maxHeight: maxHeight,
            onClose: { [weak self, weak panel] in if let panel { self?.close(panel) } },
            onHeightChange: { [weak self, weak panel] height in
                guard let self, let panel else { return }
                self.scheduleResize(panel, toHeight: height)
            },
            onCaptureAgain: { [weak self, weak panel] in
                if let panel { self?.close(panel) }
                self?.onCaptureAgain?()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onCancel = { [weak self, weak panel, weak model] in
            guard let self, let panel else { return }
            if model?.isEditing == true, model?.text.isEmpty == false {
                model?.cancelEditing()
            } else {
                self.close(panel)
            }
        }
        panel.onEdit = { [weak model] in
            guard let model, model.status == .ready, !model.isEditing else { return }
            model.beginEditing()
        }
        panel.onArrow = { [weak model] offset in
            guard let model, !model.isEditing else { return }
            withAnimation(.snappy(duration: 0.18)) { model.moveSelection(by: offset) }
        }

        // Place it under the selection if there's room, otherwise above it, otherwise at the mouse.
        let initialHeight: CGFloat = 160
        let anchorRect = selection ?? CGRect(origin: NSEvent.mouseLocation, size: .zero).insetBy(dx: -8, dy: -8)
        var x = anchorRect.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let anchor: Anchor
        if anchorRect.minY - visible.minY >= 300 || anchorRect.minY - visible.minY >= visible.maxY - anchorRect.maxY {
            anchor = .top(min(anchorRect.minY - 10, visible.maxY - 8))
        } else {
            anchor = .bottom(max(anchorRect.maxY + 10, visible.minY + 8))
        }
        entries[id] = Entry(panel: panel, model: model, anchor: anchor)
        isAdjustingFrame = true
        panel.setFrame(frame(for: anchor, x: x, width: width, height: initialHeight, in: visible), display: false)
        isAdjustingFrame = false
        panel.makeKeyAndOrderFront(nil)
        installClickMonitor()
    }

    var hasVisiblePanels: Bool { !entries.isEmpty }

    /// Closes every panel that isn't pinned.
    func closeUnpinned() {
        for entry in entries.values where !entry.model.isPinned {
            close(entry.panel)
        }
    }

    func closeAll() {
        for entry in entries.values { close(entry.panel) }
    }

    private func close(_ panel: ResultPanel) {
        let id = ObjectIdentifier(panel)
        if let entry = entries.removeValue(forKey: id) {
            entry.model.close()
            if Speaker.shared.spokenText == entry.model.analysis.text { Speaker.shared.stop() }
        }
        panel.orderOut(nil)
        panel.contentView = nil
        if entries.isEmpty, let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    // MARK: Sizing

    /// Coalesces height reports and applies the newest one after the current layout pass.
    private func scheduleResize(_ panel: ResultPanel, toHeight height: CGFloat) {
        let id = ObjectIdentifier(panel)
        let alreadyScheduled = pendingHeights[id] != nil
        pendingHeights[id] = height
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel, let height = self.pendingHeights.removeValue(forKey: id) else { return }
                self.resize(panel, toHeight: height)
            }
        }
    }

    private func resize(_ panel: ResultPanel, toHeight height: CGFloat) {
        guard let entry = entries[ObjectIdentifier(panel)] else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let height = min(height.rounded(), visible.height - 16)
        guard abs(panel.frame.height - height) >= 1 else { return }
        let frame = frame(for: entry.anchor, x: panel.frame.minX, width: panel.frame.width, height: height, in: visible)
        isAdjustingFrame = true
        panel.setFrame(frame, display: true, animate: false)
        isAdjustingFrame = false
    }

    private func frame(for anchor: Anchor, x: CGFloat, width: CGFloat, height: CGFloat, in visible: CGRect) -> CGRect {
        var y: CGFloat
        switch anchor {
        case .top(let top): y = top - height
        case .bottom(let bottom): y = bottom
        }
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func screen(for rect: CGRect?) -> NSScreen {
        guard let rect else { return NSScreen.underMouse ?? NSScreen.screens[0] }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.underMouse ?? NSScreen.screens[0]
    }

    // MARK: Window delegate

    /// Width is user-adjustable; height always follows the content.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: frameSize.width, height: sender.frame.height)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? ResultPanel else { return }
        settings.panelWidth = panel.frame.width
        // Keep the panel's top edge where it ended up.
        if var entry = entries[ObjectIdentifier(panel)], case .top = entry.anchor {
            entry.anchor = .top(panel.frame.maxY)
            entries[ObjectIdentifier(panel)] = entry
        }
    }

    /// Dragging a panel away "detaches" it: it becomes pinned, and its new position becomes its anchor.
    /// (Moves caused by resizing or by HanLens itself don't count.)
    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame, let panel = notification.object as? ResultPanel, !panel.inLiveResize,
              var entry = entries[ObjectIdentifier(panel)], panel.isVisible, NSEvent.pressedMouseButtons & 1 == 1
        else { return }
        entry.model.isPinned = true
        entry.anchor = .top(panel.frame.maxY)
        entries[ObjectIdentifier(panel)] = entry
    }

    // MARK: Click outside

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        // Global monitors see clicks in other apps only — exactly "clicked elsewhere".
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeUnpinned()
            }
        }
    }
}
