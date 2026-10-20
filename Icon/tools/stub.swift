// A do-nothing app, so a candidate icon can sit in the real Dock and in Command-Tab.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.run()
