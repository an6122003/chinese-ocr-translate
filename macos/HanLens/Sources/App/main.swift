import AppKit

// HanLens is declared a menu bar app (LSUIElement) and joins the Dock here unless that's turned off in Settings,
// so headless runs and a second copy that hands off to the first never flash a Dock icon.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppDelegate.launchesIntoDock ? .regular : .accessory)
app.run()
