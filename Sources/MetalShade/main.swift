import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory) // Menu bar only; do not show in the Dock.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
