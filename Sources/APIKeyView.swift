import SwiftUI

// MARK: - Window Controller for API Key
final class APIKeyWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "GhostWriter Initial Setup"
        window.level = .floating        // Ensure it sits above other apps
        
        self.init(window: window)
        
        let contentView = NSHostingView(rootView: APIKeyView(windowController: self))
        window.contentView = contentView
    }
    
    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        self.window?.center()
    }
}

// MARK: - API Key UI
struct APIKeyView: View {
    weak var windowController: APIKeyWindowController?
    
    @State private var apiKey: String = ""
    @State private var isSaved: Bool = false
    @State private var showError: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Welcome to GhostWriter")
                        .font(.headline)
                    Text("Zero-latency desktop dictation")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Groq API Key (Whisper-v3)")
                    .font(.caption)
                    .bold()
                
                SecureField("gsk_...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                
                if showError {
                    Text("API Key must start with 'gsk_'")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            
            HStack {
                Link("Get an API Key", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
                
                Spacer()
                
                Button("Save & Continue") {
                    saveKey()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(width: 400)
        .onAppear {
            if let existing = KeychainService.groqAPIKey() {
                self.apiKey = existing
                self.isSaved = true
            }
        }
    }
    
    private func saveKey() {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.hasPrefix("gsk_") {
            showError = true
            return
        }
        
        showError = false
        if KeychainService.saveGroqAPIKey(cleanKey) {
            isSaved = true
            windowController?.close()
            
            // Post a notification so the AppDelegate can resume initialization
            NotificationCenter.default.post(name: NSNotification.Name("APIKeySaved"), object: nil)
        }
    }
}
