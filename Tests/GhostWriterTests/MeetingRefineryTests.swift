import XCTest
@testable import GhostWriter

/// Unit tests for `MeetingRefinery.dialogueLength` — the spoken-content measure
/// that gates the end-of-meeting coverage check (skipped when too little was
/// actually said). Speaker lines are emitted as `**[HH:MM] Name:** text`.
final class MeetingRefineryTests: XCTestCase {

    func testCountsSpokenSpeakerLinesOnly() {
        let transcript = """
        ---
        title: Sync
        ---

        # Meeting Notes

        **[10:00] You:** Hello there
        **[10:01] Them:** Hi, shall we begin?
        """
        let you = "**[10:00] You:** Hello there".count
        let them = "**[10:01] Them:** Hi, shall we begin?".count
        XCTAssertEqual(MeetingRefinery.dialogueLength(of: transcript), you + them)
    }

    func testHeadingsAndFencesDoNotCountWhenSpeakerLinesPresent() {
        let withChrome = """
        # Big Heading
        ---
        **[10:00] You:** word
        """
        // Only the speaker line contributes.
        XCTAssertEqual(MeetingRefinery.dialogueLength(of: withChrome), "**[10:00] You:** word".count)
    }

    func testFallbackCountsProseWhenNoSpeakerLines() {
        // No `**[` lines → fall back to non-structural prose length.
        let transcript = """
        # Notes
        ---
        Just some free-form text.
        *[a bracketed aside that is skipped]
        """
        XCTAssertEqual(MeetingRefinery.dialogueLength(of: transcript), "Just some free-form text.".count)
    }

    func testEmptyTranscriptIsZero() {
        XCTAssertEqual(MeetingRefinery.dialogueLength(of: ""), 0)
        XCTAssertEqual(MeetingRefinery.dialogueLength(of: "# Only a heading\n---\n"), 0)
    }
}
