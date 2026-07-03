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
        Task {
            guard await ensureAuthorization() else { return }

            let content = UNMutableNotificationContent()
            content.title = "Meeting notes saved"
            content.body = "Duration \(duration) — click to open."
            content.sound = .default
            content.userInfo = ["notesPath": fileURL.path]

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
        if let path = response.notification.request.content.userInfo["notesPath"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
