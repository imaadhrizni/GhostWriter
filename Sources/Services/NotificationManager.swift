import Foundation
import UserNotifications
import AppKit

// MARK: - Notification Manager
//
// Post-meeting "notes saved" notification. Clicking it opens the notes file.
// UNUserNotificationCenter requires a real app bundle — everything is guarded
// so running the bare binary (swift build) never crashes.

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    /// True when running from a proper .app bundle (UN framework requirement).
    private var hasBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var authorized = false

    private override init() {
        super.init()
        guard hasBundle else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once, lazily, right before the first notification.
    private func ensureAuthorization() async -> Bool {
        guard hasBundle else { return false }
        if authorized { return true }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
        return authorized
    }

    /// "Meeting notes saved" — clicking opens the file.
    func notifyMeetingSaved(duration: String, fileURL: URL) {
        post(title: "Meeting notes saved",
             body: "Duration \(duration) — click to open.",
             fileURL: fileURL,
             sound: .default)
    }

    /// "Audio imported" — clicking opens the newly-created note.
    func notifyAudioImported(count: Int, fileURL: URL) {
        post(title: count == 1 ? "Audio imported" : "\(count) audio files imported",
             body: "Transcribed and filed as a meeting — click to open.",
             fileURL: fileURL,
             sound: .default)
    }

    /// "Quick note saved" — clicking opens today's QuickNotes file.
    /// Silent by design: quick notes are frequent and low-stakes.
    func notifyQuickNoteSaved(preview: String, fileURL: URL) {
        let clipped = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
        let folder = fileURL.deletingLastPathComponent().path.abbreviatingHome()
        post(title: "Quick note saved",
             body: "\(clipped)\n\(folder)",
             fileURL: fileURL,
             sound: nil)
    }

    /// "Your digest is ready" — clicking opens the interactive Digest window.
    func notifyDigestReady(period: DigestService.Period) {
        post(title: "\(period.label) digest ready",
             body: "Meetings, open action items, and quiet relationships — click to open.",
             fileURL: nil,
             userInfo: ["openDigest": true],
             sound: .default)
    }

    /// "You've passed your monthly budget" — a soft, one-per-month heads-up.
    func notifyBudgetExceeded(spent: String, budget: String) {
        post(title: "Monthly Groq budget reached",
             body: "Estimated spend this month is \(spent) (budget \(budget)). Transcription keeps working — adjust the budget in Settings → Usage & Cost.",
             fileURL: nil,
             sound: .default)
    }

    /// A Groq model the user picked was retired, so we routed to a fallback.
    func notifyModelSwitched(from: String, to: String) {
        post(title: "Groq model updated",
             body: "“\(from)” is no longer available — now using “\(to)”. Change it in Settings → AI & Models.",
             fileURL: nil, sound: nil)
    }

    /// "Something went wrong" — no click payload; also surfaced in the menu.
    func notifyError(_ message: String) {
        let clipped = message.count > 160 ? String(message.prefix(160)) + "…" : message
        post(title: "GhostWriter error", body: clipped, fileURL: nil, sound: .default)
    }

    /// Shared plumbing: authorization, content, optional click-to-open payload.
    private func post(title: String, body: String, fileURL: URL?,
                      userInfo: [String: Any] = [:], sound: UNNotificationSound?) {
        Task {
            guard await ensureAuthorization() else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound
            var info = userInfo
            if let fileURL { info["notesPath"] = fileURL.path }
            content.userInfo = info

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is "active" (menu-bar apps always are).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Open the notes file when the notification is clicked.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["openDigest"] as? Bool == true {
            NotificationCenter.default.post(name: .openDigest, object: nil)
        } else if let path = info["notesPath"] as? String {
            // Route through the app so it opens in the in-app viewer (or the
            // external editor only when that setting is on) — never bypass it.
            NotificationCenter.default.post(name: .openNoteFile, object: URL(fileURLWithPath: path))
        }
    }
}
