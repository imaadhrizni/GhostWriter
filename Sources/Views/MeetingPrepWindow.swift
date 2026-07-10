import SwiftUI
import AppKit

// MARK: - Meeting Prep Window
//
// A small, non-modal floating panel shown when a meeting starts linked to a
// catalog org/opportunity. Lists that entity's most recent notes — each row
// opens the full note in the viewer so you can read while the meeting runs.
// Non-modal on purpose: a blocking alert would trap input and you couldn't
// actually read an opened note.

final class MeetingPrepWindowController: NSWindowController {

    /// Retain presented panels so they aren't deallocated; closed ones are
    /// pruned on the next present.
    private static var open: [MeetingPrepWindowController] = []

    static func present(entityName: String, notes: [CatalogNote]) {
        open.removeAll { $0.window?.isVisible == false }
        let controller = MeetingPrepWindowController(entityName: entityName, notes: notes)
        open.append(controller)
        controller.showAndActivate()
    }

    private convenience init(entityName: String, notes: [CatalogNote]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Meeting Prep"
        window.titlebarAppearsTransparent = true
        window.level = .floating   // stays visible over the call app during the meeting

        self.init(window: window)
        window.contentView = NSHostingView(rootView: MeetingPrepView(entityName: entityName, notes: notes) { [weak window] in
            window?.close()
        })
    }

    func showAndActivate() {
        showWindow(nil)
        // Top-right of the main screen so it doesn't sit over the call window.
        if let window, let screen = NSScreen.main {
            let v = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: v.maxX - size.width - 24, y: v.maxY - size.height - 24))
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MeetingPrepView: View {
    let entityName: String
    let notes: [CatalogNote]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prep — \(entityName)").font(.headline).lineLimit(1)
            Text("Recent notes — click to read:").font(.caption).foregroundStyle(.secondary)
            ForEach(notes) { note in
                Button {
                    let url = AppSettings.shared.notesFolder.appendingPathComponent(note.filePath)
                    NotesViewerWindowController.present(fileURL: url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.title).lineLimit(1)
                            if let d = note.date {
                                Text(d, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
