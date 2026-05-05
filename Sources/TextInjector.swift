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
        guard result == .success, let element = focusedElement else { return false }

        let axElement = element as! AXUIElement
        let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            print("✅ Text injected via AX")
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
        print("✅ Text injected via clipboard")
    }
}
