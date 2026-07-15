import Testing
import Foundation
@testable import GhostWriter

/// Verifies the front-matter mutation methods (refactored onto
/// `FrontMatter.mutate` / `insertFields` / `replaceLine` / `yamlScalar`) produce
/// exactly the expected YAML. Fixtures use neutral placeholder names.
@Suite struct FrontMatterWriteTests {

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

    @Test func setTitlePlain() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("Acme Kickoff", to: u)
        #expect(read(u).contains("title: Acme Kickoff"))
        // Body line containing "title:" is untouched.
        #expect(read(u).contains("Body text with a title: colon"))
    }

    @Test func setTitleWithColonIsQuoted() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("Acme: Q3 Review", to: u)
        #expect(read(u).contains("title: \"Acme: Q3 Review\""))
    }

    @Test func setTitleQuoteCharBecomesSingle() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("The \"Big\": Deal", to: u)
        #expect(read(u).contains("title: \"The 'Big': Deal\""))
    }

    @Test func setTitleNoFrontMatterIsNoOp() {
        let u = tempNote("# Just a body\n")
        MeetingNotesWriter.setFrontMatterTitle("X", to: u)
        #expect(read(u) == "# Just a body\n")
    }

    // MARK: addFrontMatterTags

    @Test func addTagsMergesDedup() {
        let u = tempNote(base)
        MeetingNotesWriter.addFrontMatterTags(["meeting", "acme", "q3"], to: u)
        #expect(read(u).contains("tags: [meeting, ghostwriter, acme, q3]"))
    }

    @Test func addTagsNoTagsLineIsNoOp() {
        let u = tempNote("---\ntitle: X\n---\nbody\n")
        MeetingNotesWriter.addFrontMatterTags(["a"], to: u)
        #expect(!read(u).contains("tags:"))
    }

    // MARK: addMeetingMetadata

    @Test func metadataInsertsAfterTags() {
        let u = tempNote(base)
        MeetingNotesWriter.addMeetingMetadata(topics: ["topic"], people: ["Ada", "Grace"],
                                              customer: "Globex", project: "Apollo", to: u)
        let out = read(u)
        let lines = out.components(separatedBy: "\n")
        let tagsIdx = lines.firstIndex { $0.hasPrefix("tags:") }!
        // attendees/customer/project land immediately after the tags line, in order.
        #expect(lines[tagsIdx + 1] == "attendees: [Ada, Grace]")
        #expect(lines[tagsIdx + 2] == "customer: Globex")
        #expect(lines[tagsIdx + 3] == "project: Apollo")
        // Entities mirrored into tags too.
        #expect(lines[tagsIdx].contains("globex") && lines[tagsIdx].contains("apollo"))
    }

    @Test func metadataSkipsExistingKeys() {
        let u = tempNote("---\ntitle: X\ntags: [meeting]\ncustomer: Existing\n---\nbody\n")
        MeetingNotesWriter.addMeetingMetadata(topics: [], people: [], customer: "New", project: nil, to: u)
        #expect(read(u).contains("customer: Existing"))
        #expect(!read(u).contains("customer: New"))
    }

    // MARK: addFrontMatterFields

    @Test func fieldsInsertedAfterTagsWithPrefix() {
        let u = tempNote(base)
        MeetingNotesWriter.addFrontMatterFields([(key: "meeting_type", value: "customerCall")], to: u)
        let lines = read(u).components(separatedBy: "\n")
        let tagsIdx = lines.firstIndex { $0.hasPrefix("tags:") }!
        #expect(lines[tagsIdx + 1] == "gw_meeting_type: customerCall")
    }

    @Test func fieldsQuoteSignificantChars() {
        let u = tempNote(base)
        MeetingNotesWriter.addFrontMatterFields([(key: "note", value: "a: b [c]")], to: u)
        #expect(read(u).contains("gw_note: \"a: b [c]\""))
    }

    @Test func fieldsAnchorFallsBackToTitleThenTop() {
        // No tags line → insert after title.
        let u = tempNote("---\ntitle: X\n---\nbody\n")
        MeetingNotesWriter.addFrontMatterFields([(key: "k", value: "v")], to: u)
        let lines = read(u).components(separatedBy: "\n")
        #expect(lines[lines.firstIndex { $0.hasPrefix("title:") }! + 1] == "gw_k: v")
    }

    @Test func fieldsSkipExistingKeys() {
        let u = tempNote("---\ntitle: X\ngw_k: old\n---\nbody\n")
        MeetingNotesWriter.addFrontMatterFields([(key: "k", value: "new")], to: u)
        #expect(read(u).contains("gw_k: old"))
        #expect(!read(u).contains("gw_k: new"))
    }

    // MARK: body & fences preserved

    @Test func bodyAndFencesPreserved() {
        let u = tempNote(base)
        MeetingNotesWriter.setFrontMatterTitle("New", to: u)
        let out = read(u)
        #expect(out.hasPrefix("---\n"))
        #expect(out.contains("\n---\n\n# Notes\n"))
        #expect(out.hasSuffix("must not be touched.\n") || out.hasSuffix("must not be touched."))
    }
}
