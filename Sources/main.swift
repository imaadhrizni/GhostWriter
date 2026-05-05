import AppKit

// Traditional entry point — more reliable than SwiftUI @main for:
// - LSUIElement apps (no dock icon)
// - CGEventTap hotkey monitoring
// - Apps without any windows

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
