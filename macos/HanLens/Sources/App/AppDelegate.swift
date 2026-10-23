import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// URLs that arrive while launching (AppKit delivers them before `applicationDidFinishLaunching`).
    private var pendingURLs: [URL] = []
    private var isReady = false
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }
        NSApp.mainMenu = MainMenu.make()
        let headless = DebugLaunchOptions.isHeadless
        if !headless {
            NSApp.servicesProvider = ServiceProvider()
            NSUpdateDynamicServices()
            StatusMenu.shared.install()
        }
        AppController.shared.start(interactive: !headless)
        DebugLaunchOptions.apply()
        handleTerminationSignal()
        isReady = true
        for url in pendingURLs { handle(url) }
        pendingURLs = []
        Log.app.info("HanLens started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.saveNow()
    }

    /// `kill`/`pkill` (as `make install` does) quits like ⌘Q, so history is saved.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    /// Clicking the Dock icon, or opening the app again from Finder or Spotlight.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.reopen()
        return false
    }

    /// Right-clicking the Dock icon: the same actions as the menu bar item.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        StatusMenu.shared.dockMenu()
    }

    /// Whether this launch gets a Dock icon: not when it's turned off, for headless runs, or for a second copy
    /// that is about to hand off to the one already running.
    static var launchesIntoDock: Bool {
        AppSettings.showsInDock() && !DebugLaunchOptions.isHeadless && otherInstance() == nil
    }

    private static func otherInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// If another copy is already running, activate it and quit this one.
    private func handOffToRunningInstance() -> Bool {
        guard !DebugLaunchOptions.isHeadless, let other = Self.otherInstance() else { return false }
        Log.app.notice("Another HanLens instance is running; exiting")
        other.activate()
        NSApp.terminate(nil)
        return true
    }

    /// hanlens://capture · hanlens://selection · hanlens://lookup?text=学习 · hanlens://clipboard
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), url.scheme == "hanlens" else { return }
        if isReady { handle(url) } else { pendingURLs.append(url) }
    }

    private func handle(_ url: URL) {
        let app = AppController.shared
        switch url.host() {
        case "capture":
            app.capture(delay: .milliseconds(150))
        case "selection":
            app.translateSelection()
        case "clipboard":
            app.translateClipboard()
        case "settings":
            app.showSettings(tab: url.pathComponents.dropFirst().first.flatMap(SettingsTab.init(rawValue:)))
        case "lookup":
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value
            if let text, !text.isEmpty { app.lookUp(text, source: .typed, near: nil) } else { app.showLookUpPanel() }
        default:
            break
        }
    }
}

/// Handles "Look Up in HanLens" from the Services menu (works in any app, no permission needed).
final class ServiceProvider: NSObject {
    @objc func lookUpText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        AppController.shared.lookUp(text, source: .service, near: nil)
    }
}

/// The menu bar while HanLens is in front: the usual app and editing commands (so ⌘C ⌘V ⌘A ⌘Z work in its
/// windows), plus the lookup actions — handy when the menu bar item is hidden behind the notch.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About HanLens", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppActions.openSettings(_:)), keyEquivalent: ",").target = AppActions.shared
        appMenu.addItem(withTitle: "Welcome Guide", action: #selector(AppActions.openWelcome(_:)), keyEquivalent: "").target = AppActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide HanLens", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit HanLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let lookUpItem = NSMenuItem()
        lookUpItem.submenu = StatusMenu.shared.makeLookUpMenu()
        main.addItem(lookUpItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }
}

final class AppActions: NSObject {
    static let shared = AppActions()
    @objc func openSettings(_ sender: Any?) { AppController.shared.showSettings() }
    @objc func openWelcome(_ sender: Any?) { AppController.shared.showWelcome() }
}
