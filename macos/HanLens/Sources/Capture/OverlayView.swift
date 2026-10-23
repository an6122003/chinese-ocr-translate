import AppKit
import HanziKit
import QuartzCore

/// What the user selected on the frozen screen.
struct OverlaySelection {
    let snapshot: DisplaySnapshot
    /// Selected area in the overlay's flipped point coordinates (origin top-left of the screen).
    let rect: CGRect
    /// The free-form outline when the user circled instead of dragging a rectangle.
    let lasso: CGPath?

    /// The selection's rect in global AppKit screen coordinates (origin bottom-left).
    var screenRect: CGRect {
        let frame = snapshot.screen.frame
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Borderless, non-activating panel covering one screen. Non-activating means the app you were using stays
/// frontmost the whole time — no focus jump when the overlay appears or closes.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the frozen screenshot, dims everything but the selection, and turns mouse input into a selection:
/// drag a rectangle, circle/scribble a lasso, or click a detected line of text.
final class OverlayView: NSView {
    let snapshot: DisplaySnapshot
    var onSelect: ((OverlaySelection) -> Void)?
    var onCancel: (() -> Void)?

    /// Detected text lines (flipped point coordinates), filled in once whole-screen OCR finishes.
    var textLines: [CGRect] = [] {
        didSet { updateHover(at: currentMouseLocation) }
    }

    private var gesture: SelectionGesture?
    private var hoveredLine: CGRect?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let gradientContainer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let strokeMask = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let hint = HintPill()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(snapshot: DisplaySnapshot) {
        self.snapshot = snapshot
        super.init(frame: CGRect(origin: .zero, size: snapshot.screen.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setUpLayers()
        addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: max(28, snapshot.screen.safeAreaInsets.top + 18)),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUpLayers() {
        guard let root = layer else { return }
        let scale = snapshot.scale
        root.contentsScale = scale

        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        imageLayer.contentsScale = scale

        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dimLayer.path = CGPath(rect: bounds, transform: nil)

        hoverLayer.frame = bounds
        hoverLayer.fillColor = NSColor.white.withAlphaComponent(0.10).cgColor
        hoverLayer.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        hoverLayer.lineWidth = 1.5

        // Soft coloured glow under the outline.
        glowLayer.frame = bounds
        glowLayer.fillColor = nil
        glowLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
        glowLayer.lineWidth = 7
        glowLayer.lineJoin = .round
        glowLayer.lineCap = .round
        glowLayer.shadowColor = NSColor.systemPurple.cgColor
        glowLayer.shadowOpacity = 0.9
        glowLayer.shadowRadius = 9
        glowLayer.shadowOffset = .zero

        // Animated multi-colour outline, Circle-to-Search style: a rotating conic gradient seen through the stroke.
        gradientContainer.frame = bounds
        strokeMask.frame = bounds
        strokeMask.fillColor = nil
        strokeMask.strokeColor = NSColor.black.cgColor
        strokeMask.lineWidth = 3.5
        strokeMask.lineJoin = .round
        strokeMask.lineCap = .round
        gradientContainer.mask = strokeMask
        let diagonal = hypot(bounds.width, bounds.height)
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.colors = [
            NSColor(srgbRed: 0.26, green: 0.52, blue: 1.0, alpha: 1).cgColor,
            NSColor(srgbRed: 0.66, green: 0.33, blue: 0.97, alpha: 1).cgColor,
            NSColor(srgbRed: 0.93, green: 0.29, blue: 0.60, alpha: 1).cgColor,
            NSColor(srgbRed: 0.98, green: 0.62, blue: 0.16, alpha: 1).cgColor,
            NSColor(srgbRed: 0.20, green: 0.80, blue: 0.55, alpha: 1).cgColor,
            NSColor(srgbRed: 0.26, green: 0.52, blue: 1.0, alpha: 1).cgColor,
        ]
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
        gradientLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        gradientContainer.addSublayer(gradientLayer)

        for sublayer in [imageLayer, dimLayer, hoverLayer, glowLayer, gradientContainer] {
            sublayer.actions = ["path": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            root.addSublayer(sublayer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 3.2
        spin.repeatCount = .infinity
        gradientLayer.add(spin, forKey: "spin")
        updateHover(at: currentMouseLocation)
    }

    private var currentMouseLocation: CGPoint? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    // MARK: Drawing state

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let gesture, gesture.travelled > 2 {
            let outline = gesture.outline
            dim.addPath(outline)
            glowLayer.path = outline
            strokeMask.path = outline
            hoverLayer.path = nil
        } else {
            glowLayer.path = nil
            strokeMask.path = nil
            if let hoveredLine {
                let highlight = CGPath(roundedRect: hoveredLine, cornerWidth: 5, cornerHeight: 5, transform: nil)
                dim.addPath(highlight)
                hoverLayer.path = highlight
            } else {
                hoverLayer.path = nil
            }
        }
        dimLayer.path = dim
        CATransaction.commit()
    }

    private func lineRect(at point: CGPoint?) -> CGRect? {
        guard let point else { return nil }
        return textLines.first { $0.insetBy(dx: -6, dy: -4).contains(point) }.map { $0.insetBy(dx: -6, dy: -4) }
    }

    private func updateHover(at point: CGPoint?) {
        guard gesture == nil else { return }
        let line = lineRect(at: point)
        if line != hoveredLine {
            hoveredLine = line
            refresh()
        }
        (line == nil ? NSCursor.crosshair : NSCursor.pointingHand).set()
    }

    // MARK: Mouse

    override func cursorUpdate(with event: NSEvent) {
        (hoveredLine == nil ? NSCursor.crosshair : NSCursor.pointingHand).set()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        gesture = SelectionGesture(start: convert(event.locationInWindow, from: nil))
        NSCursor.crosshair.set()
        hint.animator().alphaValue = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        gesture?.add(CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height)))
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = gesture else { return }
        gesture = nil
        let point = convert(event.locationInWindow, from: nil)

        if finished.travelled < 5 {
            // A click: pick the line of text under the pointer, if any.
            if let line = lineRect(at: point) {
                select(line.intersection(bounds), lasso: nil)
            } else {
                refresh()
                hint.animator().alphaValue = 1
                hint.nudge()
            }
            return
        }
        let rect = finished.rect.intersection(bounds)
        guard rect.width >= 8, rect.height >= 8 else {
            refresh()
            hint.animator().alphaValue = 1
            return
        }
        select(rect, lasso: finished.shape == .lasso ? finished.lassoPath : nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onCancel?()                                     // esc
        case 36, 76: select(bounds, lasso: nil)                  // return / enter: whole screen
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
                select(bounds, lasso: nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func select(_ rect: CGRect, lasso: CGPath?) {
        onSelect?(OverlaySelection(snapshot: snapshot, rect: rect, lasso: lasso))
    }

    // MARK: Previews

    /// Draws a gesture through `points` as if the user were dragging (used to render previews).
    func previewGesture(through points: [CGPoint]) {
        guard let first = points.first else { return }
        var preview = SelectionGesture(start: first)
        for point in points.dropFirst() { preview.add(point) }
        gesture = preview
        hint.alphaValue = 0
        refresh()
    }

    /// Shows the hover highlight for the line under `point` (used to render previews).
    func previewHover(at point: CGPoint) {
        updateHover(at: point)
    }
}

/// The instruction pill at the top of the overlay.
final class HintPill: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithAttributedString: Self.text)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static var text: NSAttributedString {
        let result = NSMutableAttributedString()
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        result.append(NSAttributedString(string: "Drag or circle Chinese text", attributes: normal))
        result.append(NSAttributedString(string: "   ·   click a line   ·   ", attributes: dim))
        result.append(NSAttributedString(string: "↩", attributes: key))
        result.append(NSAttributedString(string: " whole screen   ·   ", attributes: dim))
        result.append(NSAttributedString(string: "esc", attributes: key))
        result.append(NSAttributedString(string: " cancel", attributes: dim))
        return result
    }

    /// Small shake to say "nothing to select here".
    func nudge() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -8, 8, -5, 5, 0]
        animation.duration = 0.35
        layer?.add(animation, forKey: "nudge")
    }
}
