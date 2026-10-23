import AppKit
import HanziKit

/// Freezes the screens, shows the selection overlay, and reports what the user selected.
final class CaptureController {
    var onSelection: ((OverlaySelection) -> Void)?
    var onPermissionMissing: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    /// Called right before the screens are captured (e.g. to close unpinned panels).
    var willCapture: (() -> Void)?

    private var windows: [OverlayWindow] = []
    private var lineDetection: Task<Void, Never>?
    /// The capture being prepared (delay + screenshot); cancelled if the user presses the hotkey again.
    private var startTask: Task<Void, Never>?
    /// The app that was in front before the overlay, given focus back afterwards.
    private var previousApp: NSRunningApplication?

    var isActive: Bool { startTask != nil || !windows.isEmpty }

    /// Starts a capture, or cancels the one in progress (pressing the hotkey twice).
    func toggle() {
        if isActive { cancel() } else { start() }
    }

    func start(delay: Duration = .zero) {
        guard !isActive else { return }
        guard Permissions.hasScreenRecording else {
            Log.capture.notice("OCR capture requested, but Screen Recording permission is missing")
            onPermissionMissing?()
            return
        }
        Log.capture.notice("OCR capture requested")
        willCapture?()
        startTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            do {
                let snapshots = try await ScreenCapturer.captureAllScreens()
                guard !Task.isCancelled else { return }
                startTask = nil
                present(snapshots)
            } catch {
                guard !Task.isCancelled else { return }
                startTask = nil
                Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
                onFailure?(error)
            }
        }
    }

    /// Shows the overlay over a given image instead of the live screen (for demos and testing).
    func present(image: CGImage, on screen: NSScreen) {
        guard !isActive else { return }
        present([DisplaySnapshot(screen: screen, image: image)])
    }

    private func present(_ snapshots: [DisplaySnapshot]) {
        // Become the active app while the overlay is up: that guarantees the crosshair cursor and keyboard
        // (esc / return). Focus goes back to the previous app when the overlay closes.
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            previousApp = front
        }
        NSApp.activate()
        let mouseScreen = NSScreen.underMouse
        var views: [(OverlayView, DisplaySnapshot)] = []
        for snapshot in snapshots {
            let window = OverlayWindow(screen: snapshot.screen)
            let view = OverlayView(snapshot: snapshot)
            view.onSelect = { [weak self] selection in self?.finish(with: selection) }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append((view, snapshot))
            if snapshot.screen == mouseScreen {
                window.makeKey()
                window.makeFirstResponder(view)
            }
        }
        NSCursor.crosshair.set()
        detectLines(in: views.sorted { lhs, _ in lhs.1.screen == mouseScreen })
    }

    /// Runs OCR on each whole screen in the background so lines can be hovered and clicked.
    private func detectLines(in views: [(OverlayView, DisplaySnapshot)]) {
        lineDetection = Task {
            for (view, snapshot) in views {
                let started = Date()
                guard let lines = try? await TextRecognizer().lines(in: snapshot.image, minimumTextHeight: 0.004),
                      !Task.isCancelled else { return }
                let size = view.bounds.size
                view.textLines = lines
                    .filter { CJK.containsHan($0.text) }
                    .map { CGRect(x: $0.box.minX * size.width, y: $0.box.minY * size.height,
                                  width: $0.box.width * size.width, height: $0.box.height * size.height) }
                Log.capture.info("Line detection: \(lines.count) lines in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        }
    }

    private func finish(with selection: OverlaySelection) {
        close()
        onSelection?(selection)
    }

    func cancel() {
        close()
    }

    private func close() {
        startTask?.cancel()
        startTask = nil
        lineDetection?.cancel()
        lineDetection = nil
        let hadOverlay = !windows.isEmpty
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        NSCursor.arrow.set()
        if hadOverlay, let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        previousApp = nil
    }
}
