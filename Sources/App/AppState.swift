import Foundation

// MARK: - App State

/// Observable state shared across the app — drives the GlowOverlay UI.
@Observable
final class AppState {
    var recordingState: RecordingState = .idle
    var audioLevel: Float = 0.0
    // Meeting mode
    var isMeetingMode: Bool = false
    var isSpeakerActive: Bool = false
    var meetingCaption: String = ""
    /// The most recent surfaced error, shown in the menu until dismissed.
    var lastError: String?
}

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case listening
    case processing
    case done
    case error(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.listening, .listening),
             (.processing, .processing), (.done, .done):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
