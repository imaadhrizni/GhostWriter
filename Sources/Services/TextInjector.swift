import ApplicationServices
import AppKit
import Foundation

/// Injects text at the cursor using AXUIElement. Falls back to clipboard paste.
final class TextInjector {

    func inject(text: String) {
        if !injectViaAccessibility(text: text) {
            injectViaClipboard(text: text)
        }
    }

    private func injectViaAccessibility(text: String) -> Bool {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let axElement = element as! AXUIElement

        // Never set an AX attribute on our OWN focused element: doing so
        // re-enters GhostWriter's main thread synchronously and hangs/crashes
        // the app. When dictating into GhostWriter's own fields, fall through
        // to the clipboard-paste path (routes through the normal responder
        // chain) so the text still lands, safely.
        var pid: pid_t = 0
        if AXUIElementGetPid(axElement, &pid) == .success, pid == getpid() {
            Log.dictation.debug("↩︎ Self-focused — using clipboard path")
            return false
        }

        let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            Log.dictation.debug("✅ Text injected via AX")
            return true
        }
        return false
    }

    private func injectViaClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let saved = savedString {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        Log.dictation.debug("✅ Text injected via clipboard")
    }
}
