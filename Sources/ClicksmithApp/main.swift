import AppKit

// Plain AppKit start, no SwiftUI App/Scene: a SwiftUI `Settings` scene showed an empty
// "Clicksmith Settings" window. No menu bar icon, no Dock icon: Finder starts Clicksmith on
// demand (clicksmith:// URL); it shows a progress panel for long jobs and quits when idle.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
