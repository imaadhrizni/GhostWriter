import SwiftUI

// MARK: - Window Controller

/// Hosts the first-run welcome tour. Shown once after the API key + permission
/// flow on first launch, and re-openable any time from the menu (Welcome to
/// GhostWriter…). "Seen" state lives in `AppSettings.onboardingCompleted`.
final class OnboardingWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "Welcome to GhostWriter"
        window.level = .floating

        self.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(windowController: self))
    }

    func showAndActivate() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Tour content

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let symbol: String
    let tint: Color
    let title: String
    let body: String
}

private let onboardingPages: [OnboardingPage] = [
    .init(symbol: "waveform.circle.fill", tint: .cyan,
          title: "Dictate anywhere",
          body: "Hold the Right Option key and speak — GhostWriter transcribes, polishes for the app you're in, and types the result straight at your cursor. Prefer hands-free? Switch to tap-to-lock or toggle in Settings ▸ Dictation."),
    .init(symbol: "person.2.wave.2.fill", tint: .indigo,
          title: "Capture meetings",
          body: "Press ⌃⌥M to start Meeting Mode. GhostWriter records both you and the other participants, then writes structured notes — summary, decisions, action items, and chapters — when the call ends. No screen-recording permission needed."),
    .init(symbol: "square.grid.2x2.fill", tint: .orange,
          title: "Organise with the Catalog",
          body: "A lightweight CRM beside your notes: organisations, people, projects, tags, and a POC tracker. Meetings link into it automatically, so every account's history is one click away."),
    .init(symbol: "sparkle.magnifyingglass", tint: .purple,
          title: "Ask across everything",
          body: "Ask Anything (⌃⌥ or the menu) searches all your notes with on-device semantic search and answers with citations you can open. Great for “what did we decide with Acme?” or “which POCs are at risk?”"),
    .init(symbol: "lock.shield.fill", tint: .green,
          title: "Private by design",
          body: "Your notes are plain files on your Mac. Semantic search runs fully on-device, and Local-only mode keeps everything offline using Apple's on-device transcription and intelligence. Your API key is stored in the Keychain, never in a file."),
]

// MARK: - Tour UI

struct OnboardingView: View {
    weak var windowController: OnboardingWindowController?
    @State private var index = 0

    private var page: OnboardingPage { onboardingPages[index] }
    private var isLast: Bool { index == onboardingPages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            VStack(spacing: 18) {
                Image(systemName: page.symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(page.tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 90)
                    .animation(.easeInOut, value: index)

                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(page.body)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)

            // Page dots
            HStack(spacing: 8) {
                ForEach(onboardingPages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? page.tint : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 20)

            Divider()

            // Controls
            HStack {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                if index > 0 {
                    Button("Back") { withAnimation { index -= 1 } }
                }
                Button(isLast ? "Get Started" : "Next") {
                    if isLast { finish() }
                    else { withAnimation { index += 1 } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 460)
    }

    private func finish() {
        AppSettings.shared.onboardingCompleted = true
        windowController?.close()
    }
}
