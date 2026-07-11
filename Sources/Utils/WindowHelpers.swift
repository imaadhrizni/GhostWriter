import AppKit

// MARK: - Window Helpers

extension NSWindowController {
    /// Bring the app forward and show this controller's window as key — the
    /// standard present sequence shared by every menu-opened window. Controllers
    /// that need extra placement (centering, positioning) define their own show
    /// method and call this after arranging the window.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
