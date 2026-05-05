import AppKit

// MARK: - App Detector

/// Detects the currently active application and categorizes it
/// for context-aware text polishing.
///
/// Uses NSWorkspace — native, instant, no polling needed.
final class AppDetector {

    /// Get the current active application context.
    func currentApp() -> AppContext {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(appName: "Unknown", bundleID: "", category: .general)
        }

        let bundleID = frontApp.bundleIdentifier ?? ""
        let appName = frontApp.localizedName ?? "Unknown"
        let category = categorize(bundleID: bundleID)

        return AppContext(
            appName: appName,
            bundleID: bundleID,
            category: category
        )
    }

    /// Categorize the app based on its bundle identifier.
    private func categorize(bundleID: String) -> AppCategory {
        let id = bundleID.lowercased()

        // Messaging apps
        if messagingBundleIDs.contains(where: { id.contains($0) }) {
            return .messaging
        }

        // Email apps
        if emailBundleIDs.contains(where: { id.contains($0) }) {
            return .email
        }

        // Code editors
        if codeBundleIDs.contains(where: { id.contains($0) }) {
            return .code
        }

        // Browsers
        if browserBundleIDs.contains(where: { id.contains($0) }) {
            return .browser
        }

        // Notes / Writing apps
        if notesBundleIDs.contains(where: { id.contains($0) }) {
            return .notes
        }

        return .general
    }

    // MARK: - Bundle ID Patterns

    private let messagingBundleIDs = [
        "com.tinyspeck.slackmacgap",   // Slack
        "slack",
        "com.hnc.discord",             // Discord
        "discord",
        "ru.keepcoder.telegram",       // Telegram
        "telegram",
        "com.facebook.archon",         // Messenger
        "messenger",
        "net.whatsapp",                // WhatsApp
        "whatsapp",
        "com.microsoft.teams",         // Teams
        "teams",
        "com.apple.ichat",             // Messages
        "messages",
    ]

    private let emailBundleIDs = [
        "com.apple.mail",              // Apple Mail
        "com.microsoft.outlook",       // Outlook
        "com.google.gmail",            // Gmail app
        "com.readdle.spark",           // Spark
        "com.superhuman.mail",         // Superhuman
    ]

    private let codeBundleIDs = [
        "com.microsoft.vscode",        // VS Code
        "vscode",
        "com.todesktop.cursor",        // Cursor
        "cursor",
        "com.apple.dt.xcode",          // Xcode
        "xcode",
        "com.sublimetext",             // Sublime Text
        "com.jetbrains",               // JetBrains IDEs
        "com.googlecode.iterm2",       // iTerm2
        "com.apple.terminal",          // Terminal
        "dev.warp.warp-stable",        // Warp
    ]

    private let browserBundleIDs = [
        "com.apple.safari",            // Safari
        "com.google.chrome",           // Chrome
        "org.mozilla.firefox",         // Firefox
        "com.brave.browser",           // Brave
        "company.thebrowser.browser",  // Arc
        "com.operasoftware.opera",     // Opera
        "com.microsoft.edgemac",       // Edge
    ]

    private let notesBundleIDs = [
        "com.apple.notes",             // Notes
        "com.apple.iwork.pages",       // Pages
        "notion.id",                   // Notion
        "com.craft.craft",             // Craft
        "md.obsidian",                 // Obsidian
        "com.ulyssesapp.mac",          // Ulysses
        "com.bear.bear",               // Bear
    ]
}

// MARK: - App Context

/// Represents the current application context for polishing.
struct AppContext {
    let appName: String
    let bundleID: String
    let category: AppCategory
}

// MARK: - App Category

enum AppCategory: String {
    case messaging  // Slack, Discord, Messages
    case email      // Mail, Outlook
    case code       // VS Code, Cursor, Xcode
    case browser    // Safari, Chrome
    case notes      // Notes, Notion, Obsidian
    case general    // Everything else
}
