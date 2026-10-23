import AppKit
import ScreenCaptureKit

/// A frozen image of one screen at full pixel resolution.
struct DisplaySnapshot {
    let screen: NSScreen
    /// Pixel image with a top-left origin, covering `screen.frame`.
    let image: CGImage

    /// Pixels per point.
    var scale: CGFloat { CGFloat(image.width) / max(screen.frame.width, 1) }

    /// Crops a rect given in the overlay's flipped point coordinates.
    func crop(_ rect: CGRect) -> CGImage? {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty else { return nil }
        return image.cropping(to: pixels)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen containing the mouse pointer.
    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}

enum ScreenCapturer {
    enum Failure: LocalizedError {
        case noDisplays

        var errorDescription: String? { "No displays could be captured." }
    }

    /// Captures every screen, leaving HanLens' own windows (e.g. a pinned result panel) out of the picture.
    static func captureAllScreens() async throws -> [DisplaySnapshot] {
        let started = Date()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == ownPID }

        // Capture the screen under the mouse first so it is ready soonest.
        let screens = NSScreen.screens.sorted { lhs, _ in lhs == NSScreen.underMouse }
        var snapshots: [DisplaySnapshot] = []
        for screen in screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            if let name = screen.colorSpace?.cgColorSpace?.name {
                configuration.colorSpaceName = name // match the display so the frozen frame doesn't shift colour
            }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots.append(DisplaySnapshot(screen: screen, image: image))
        }
        guard !snapshots.isEmpty else { throw Failure.noDisplays }
        Log.capture.notice("Captured \(snapshots.count) screen(s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return snapshots
    }
}

/// Repeatedly captures one area of one screen (for following subtitles), reusing the capture filter.
final class RegionCapturer {
    private let rect: CGRect
    private let screen: NSScreen
    private var filter: SCContentFilter?

    /// `rect` is in the screen's top-left-origin point coordinates (as in ``OverlaySelection/rect``).
    init(rect: CGRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
    }

    func capture() async throws -> CGImage {
        let filter = try await currentFilter()
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.sourceRect = rect
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func currentFilter() async throws -> SCContentFilter {
        if let filter { return filter }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
            throw ScreenCapturer.Failure.noDisplays
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let created = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID },
                                      exceptingWindows: [])
        filter = created
        return created
    }
}
