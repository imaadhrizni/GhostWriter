import XCTest
import Foundation
@testable import GhostWriter

/// Verifies the front-matter mutation methods (refactored onto
/// `FrontMatter.mutate` / `insertFields` / `replaceLine` / `yamlScalar`) produce
/// exactly the expected YAML. Fixtures use neutral placeholder names.
final class FrontMatterWriteTests: XCTestCase {

    private func tempNote(_ content: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-fm-\(UUID().uuidString).md")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private let base = """
    ---
    title: Untitled
    tags: [meeting, ghostwriter]
    ---

    # Notes

    Body text with a title: colon that must not be touched.
    """

    // MARK: setFrontMatterTitle

    func testSetTitlePlain() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("Acme Kickoff", to: u)
        XCTAssertTrue(read(u).contains("title: Acme Kickoff"))
        // Body line containing "title:" is untouched.
        XCTAssertTrue(read(u).contains("Body text with a title: colon"))
    }

    func testSetTitleWithColonIsQuoted() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("Acme: Q3 Review", to: u)
        XCTAssertTrue(read(u).contains("title: \"Acme: Q3 Review\""))
    }

    func testSetTitleQuoteCharBecomesSingle() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("The \"Big\": Deal", to: u)
        XCTAssertTrue(read(u).contains("title: \"The 'Big': Deal\""))
    }

    func testSetTitleNoFrontMatterIsNoOp() {
        let u = tempNote("# Just a body\n")
        MeetingNotesWriter.setFrontMatterTitle("X", to: u)
        XCTAssertTrue(read(u) == "# Just a body\n")
    }

    // MARK: addFrontMatterTags

    func testAddTagsMergesDedup() {
        let u = tempNote(base)
        MeetingNotesWriter.addFrontMatterTags(["meeting", "acme", "q3"], to: u)
        XCTAssertTrue(read(u).contains("tags: [meeting, ghostwriter, acme, q3]"))
    }

    func testAddTagsNoTagsLineIsNoOp() {
        let u = tempNote("---\ntitle: X\n---\nbody\n")
        MeetingNotesWriter.addFrontMatterTags(["a"], to: u)
        XCTAssertTrue(!read(u).contains("tags:"))
    }

    // MARK: addMeetingMetadata

    func testMetadataInsertsAfterTags() {
        let u = tempNote(base)
        MeetingNotesWriter.addMeetingMetadata(topics: ["topic"], people: ["Ada", "Grace"],
                                              customer: "Globex", project: "Apollo", to: u)
        let out = read(u)
        let lines = out.components(separatedBy: "\n")
        let tagsIdx = lines.firstIndex { $0.hasPrefix("tags:") }!
        // attendees/customer/project land immediately after the tags line, in order.
        XCTAssertTrue(lines[tagsIdx + 1] == "attendees: [Ada, Grace]")
        XCTAssertTrue(lines[tagsIdx + 2] == "customer: Globex")
        XCTAssertTrue(lines[tagsIdx + 3] == "project: Apollo")
        // Entities mirrored into tags too.
        XCTAssertTrue(lines[tagsIdx].contains("globex") && lines[tagsIdx].contains("apollo"))
    }

    func testMetadataSkipsExistingKeys() {
        let u = tempNote("---\ntitle: X\ntags: [meeting]\ncustomer: Existing\n---\nbody\n")
        MeetingNotesWriter.addMeetingMetadata(topics: [], people: [], customer: "New", project: nil, to: u)
        XCTAssertTrue(read(u).contains("customer: Existing"))
        XCTAssertTrue(!read(u).contains("customer: New"))
    }

    // MARK: addFrontMatterFields

    func testFieldsInsertedAfterTagsWithPrefix() {
        let u = tempNote(base)
        MeetingNotesWriter.addFrontMatterFields([(key: "meeting_type", value: "customerCall")], to: u)
        let lines = read(u).components(separatedBy: "\n")
        let tagsIdx = lines.firstIndex { $0.hasPrefix("tags:") }!
        XCTAssertTrue(lines[tagsIdx + 1] == "gw_meeting_type: customerCall")
    }

    func testFieldsQuoteSignificantChars() {
        let u = tempNote(base)
        MeetingNotesWriter.addFrontMatterFields([(key: "note", value: "a: b [c]")], to: u)
        XCTAssertTrue(read(u).contains("gw_note: \"a: b [c]\""))
    }

    func testFieldsAnchorFallsBackToTitleThenTop() {
        // No tags line → insert after title.
        let u = tempNote("---\ntitle: X\n---\nbody\n")
        MeetingNotesWriter.addFrontMatterFields([(key: "k", value: "v")], to: u)
        let lines = read(u).components(separatedBy: "\n")
        XCTAssertTrue(lines[lines.firstIndex { $0.hasPrefix("title:") }! + 1] == "gw_k: v")
    }

    func testFieldsSkipExistingKeys() {
        let u = tempNote("---\ntitle: X\ngw_k: old\n---\nbody\n")
        MeetingNotesWriter.addFrontMatterFields([(key: "k", value: "new")], to: u)
        XCTAssertTrue(read(u).contains("gw_k: old"))
        XCTAssertTrue(!read(u).contains("gw_k: new"))
    }

    // MARK: body & fences preserved

    func testBodyAndFencesPreserved() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("New", to: u)
        let out = read(u)
        XCTAssertTrue(out.hasPrefix("---\n"))
        XCTAssertTrue(out.contains("\n---\n\n# Notes\n"))
        XCTAssertTrue(out.hasSuffix("must not be touched.\n") || out.hasSuffix("must not be touched."))
    }
}
