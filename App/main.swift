import AppKit

// Mane: a mirror that drops out of the notch and lets you try haircuts on, live.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon; lives in the notch and the menu bar
    app.run()
    _ = delegate
}
