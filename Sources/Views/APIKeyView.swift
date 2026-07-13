import SwiftUI

// MARK: - Window Controller for API Key

final class APIKeyWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "GhostWriter Setup"
        window.level = .floating        // Ensure it sits above other apps

        self.init(window: window)

        let contentView = NSHostingView(rootView: APIKeyView(windowController: self))
        window.contentView = contentView
    }

    func showAndActivate() {
        window?.center()
        bringToFront()
    }
}

// MARK: - API Key UI

struct APIKeyView: View {
    weak var windowController: APIKeyWindowController?

    @State private var apiKey = ""
    @State private var isRevealed = false
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var hasExistingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            // ── Header ─────────────────────────────────────────
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white, .cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to GhostWriter")
                        .font(.title3.bold())
                    Text("Dictation and meeting notes, powered by Groq")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // ── Key input ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Groq API Key")
                        .font(.caption.bold())
                    if hasExistingKey {
                        Text("· already configured — enter a new key to replace it")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Group {
                        if isRevealed {
                            TextField("gsk_…", text: $apiKey)
                        } else {
                            SecureField("gsk_…", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .disableAutocorrection(true)
                    .onSubmit { verifyAndSave() }

                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isRevealed ? "Hide key" : "Show key")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("Stored securely in the macOS Keychain — never written to disk in plain text.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            // ── Actions ────────────────────────────────────────
            HStack {
                Link(destination: URL(string: "https://console.groq.com/keys")!) {
                    Label("Get a free API key", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }

                Spacer()

                if hasExistingKey {
                    Button("Cancel") { windowController?.close() }
                        .keyboardShortcut(.cancelAction)
                }

                Button {
                    verifyAndSave()
                } label: {
                    if isVerifying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Verifying…")
                        }
                    } else {
                        Text("Verify & Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isVerifying || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440, height: 320)
        .onAppear {
            hasExistingKey = KeychainService.groqAPIKey() != nil
        }
    }

    // MARK: - Verify & Save

    private func verifyAndSave() {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleanKey.hasPrefix("gsk_") else {
            errorMessage = "Groq keys start with “gsk_”. Check for a copy-paste mix-up."
            return
        }

        errorMessage = nil
        isVerifying = true

        Task {
            let valid = await Self.verify(key: cleanKey)
            await MainActor.run {
                isVerifying = false
                guard valid else {
                    errorMessage = "Groq rejected this key. Make sure it's active in your Groq console."
                    return
                }
                guard KeychainService.saveGroqAPIKey(cleanKey) else {
                    errorMessage = "Could not save to Keychain. Try again."
                    return
                }
                windowController?.close()
                NotificationCenter.default.post(name: NSNotification.Name("APIKeySaved"), object: nil)
            }
        }
    }

    /// Cheap live check: list models with the key. 200 = valid, 401/403 = bad key.
    /// Network failures pass the key through — no false negatives when offline.
    private static func verify(key: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return true }
            return http.statusCode != 401 && http.statusCode != 403
        } catch {
            Log.api.warning("⚠️ Key verification skipped (network error) — saving unverified")
            return true
        }
    }
}
