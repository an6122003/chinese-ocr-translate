import AppKit

/// The menu bar item and its menu.
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()
        item.button?.toolTip = "HanLens"
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refresh()
    }

    /// Rebuilds the menu (shortcuts and toggles may have changed).
    func refresh() {
        menu.removeAllItems()
        addActions(to: menu)
        menu.addItem(.separator())
        let quit = item("Quit HanLens", symbol: nil, shortcut: nil) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The Dock icon's menu: the same actions (the Dock adds Quit itself).
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        addActions(to: menu)
        return menu
    }

    /// The “Look Up” menu in the app's menu bar, rebuilt each time it opens.
    func makeLookUpMenu() -> NSMenu {
        let menu = NSMenu(title: "Look Up")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            refresh()
        } else {
            menu.removeAllItems()
            addActions(to: menu, includeAppItems: false)
        }
    }

    /// The lookup actions, then History; with `includeAppItems`, also Settings and the Welcome Guide.
    private func addActions(to menu: NSMenu, includeAppItems: Bool = true) {
        let app = AppController.shared
        let settings = app.settings
        menu.addItem(item("OCR Capture (Circle to Search)", symbol: "viewfinder", shortcut: settings.captureShortcut) {
            app.capture(delay: .milliseconds(250))
        })
        menu.addItem(item("Translate Selected Text", symbol: "selection.pin.in.out", shortcut: settings.translateSelectionShortcut) {
            // Give the menu time to close so the previous app is frontmost again.
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                app.translateSelection()
            }
        })
        menu.addItem(item("Look Up…", symbol: "character.book.closed.zh", shortcut: settings.lookUpShortcut) {
            app.showLookUpPanel()
        })
        menu.addItem(item("Look Up Clipboard", symbol: "doc.on.clipboard", shortcut: nil) {
            app.translateClipboard()
        })
        menu.addItem(.separator())

        let typing = item("Pinyin Tone Typing (ma1 → mā)", symbol: "keyboard", shortcut: settings.toneTypingShortcut) {
            app.setToneTyping(!settings.toneTypingEnabled)
        }
        typing.state = settings.toneTypingEnabled ? .on : .off
        menu.addItem(typing)
        menu.addItem(.separator())

        menu.addItem(item("History", symbol: "clock.arrow.circlepath", shortcut: nil) { app.showHistory() })
        guard includeAppItems else { return }
        let settingsItem = item("Settings…", symbol: "gearshape", shortcut: nil) { app.showSettings() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("Welcome Guide", symbol: "questionmark.circle", shortcut: nil) { app.showWelcome() })
    }

    private func item(_ title: String, symbol: String?, shortcut: KeyCombo?, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let shortcut, let key = shortcut.menuKeyEquivalent {
            // Shown for reference; the global hotkey does the real work.
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        return item
    }
}

/// An NSMenuItem that runs a closure. (NSMenuItem's initializers aren't main-actor isolated, so neither is this.)
nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() {
        let handler = handler // capture only the (Sendable) closure, not the menu item
        MainActor.assumeIsolated { handler() }
    }
}

extension KeyCombo {
    /// The lowercase key for an NSMenuItem key equivalent, when the key is a printable character.
    var menuKeyEquivalent: String? {
        guard KeyCombo.specialKeyNames[Int(keyCode)] == nil, let character = KeyCombo.characterForKeyCode(keyCode) else { return nil }
        return character.lowercased()
    }
}

/// The menu bar glyph: 文 inside viewfinder corners, drawn as a template image.
enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            let corner: CGFloat = 4.5
            let inset: CGFloat = 1.25
            let r = rect.insetBy(dx: inset, dy: inset)
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            // Four viewfinder corners.
            path.move(to: NSPoint(x: r.minX, y: r.maxY - corner)); path.line(to: NSPoint(x: r.minX, y: r.maxY)); path.line(to: NSPoint(x: r.minX + corner, y: r.maxY))
            path.move(to: NSPoint(x: r.maxX - corner, y: r.maxY)); path.line(to: NSPoint(x: r.maxX, y: r.maxY)); path.line(to: NSPoint(x: r.maxX, y: r.maxY - corner))
            path.move(to: NSPoint(x: r.maxX, y: r.minY + corner)); path.line(to: NSPoint(x: r.maxX, y: r.minY)); path.line(to: NSPoint(x: r.maxX - corner, y: r.minY))
            path.move(to: NSPoint(x: r.minX + corner, y: r.minY)); path.line(to: NSPoint(x: r.minX, y: r.minY)); path.line(to: NSPoint(x: r.minX, y: r.minY + corner))
            path.stroke()

            let font = NSFont(name: "PingFangSC-Semibold", size: 10.5) ?? .systemFont(ofSize: 10.5, weight: .semibold)
            let glyph = NSAttributedString(string: "文", attributes: [.font: font, .foregroundColor: NSColor.black])
            let glyphSize = glyph.size()
            glyph.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2 + 0.3))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "HanLens"
        return image
    }
}

/// A brief message near the mouse pointer that fades away.
enum Toast {
    private static var window: NSPanel?

    static func show(_ message: String) {
        window?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 320
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
        ])
        let size = effect.fittingSize
        let mouse = NSEvent.mouseLocation
        let panel = NSPanel(contentRect: NSRect(x: mouse.x + 12, y: mouse.y - size.height - 12, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        window = panel
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            panel.orderOut(nil)
            if window === panel { window = nil }
        }
    }
}
