import ApplicationServices
import AppKit
import Foundation

/// Injects text at the cursor using AXUIElement. Falls back to clipboard paste.
final class TextInjector {

    /// Apps where the AX text path is unreliable — their web `contenteditable`
    /// fields report a successful `AXSelectedText` set but often insert nothing,
    /// so dictation silently drops. Paste (⌘V) lands reliably, so we route these
    /// straight to it. Covers browsers (Gmail compose & chat, Google Docs, …)
    /// and Electron/Chromium desktop apps (Claude, Slack, VS Code, Discord, …),
    /// which share the same Chromium text-input behaviour.
    private static let pasteOnlyBundleIDs: Set<String> = [
        // Browsers
        "com.apple.safari", "com.apple.safaritechnologypreview",
        "com.google.chrome", "com.google.chrome.canary",
        "com.brave.browser", "com.microsoft.edgemac",
        "company.thebrowser.browser", "org.mozilla.firefox",
        "com.operasoftware.opera", "com.vivaldi.vivaldi",
        // Electron / Chromium desktop apps
        "com.anthropic.claudefordesktop", "com.openai.chat",
        "com.tinyspeck.slackmacgap", "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.hnc.discord", "notion.id", "md.obsidian",
        "com.microsoft.teams2", "com.microsoft.teams",
        "com.figma.desktop", "com.linear", "com.spotify.client",
        "com.electron.postman", "com.github.atom",
    ]

    func inject(text: String) {
        if shouldPaste() {
            injectViaClipboard(text: text)
            return
        }
        if !injectViaAccessibility(text: text) {
            injectViaClipboard(text: text)
        }
    }

    /// True when the frontmost app is a known paste-only app (built-in list or
    /// the user's own `pasteOnlyApps`), so we skip AX and go straight to ⌘V.
    private func shouldPaste() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier?.lowercased() else { return false }
        return Self.pasteOnlyBundleIDs.contains(id)
            || AppSettings.shared.pasteOnlyBundleIDs.contains(id)
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
