import XCTest
@testable import GhostWriter

/// Unit tests for the read/parse side of `FrontMatter` — the single shared
/// implementation that separates YAML metadata from the note body and reads
/// scalar fields, title, and tags. (The write side is covered by
/// `FrontMatterWriteTests`.) Fixtures use neutral placeholder names.
final class FrontMatterReadTests: XCTestCase {

    private let note = """
    ---
    title: "Acme: Q3 Review"
    tags: [meeting, ghostwriter, acme]
    customer: Globex
    ---

    # Notes

    Body line with a title: colon that must not be parsed as a field.
    """

    // MARK: split / body

    func testSplitSeparatesFrontMatterAndBody() {
        let (fm, body) = FrontMatter.split(note)
        XCTAssertNotNil(fm)
        XCTAssertTrue(fm!.contains("customer: Globex"))
        // Body excludes the fences and starts after the closing `---`.
        XCTAssertFalse(body.contains("title:"))
        XCTAssertTrue(body.contains("# Notes"))
    }

    func testSplitNoFrontMatterReturnsNilAndWholeText() {
        let (fm, body) = FrontMatter.split("# Just a body\n\nText.")
        XCTAssertNil(fm)
        XCTAssertEqual(body, "# Just a body\n\nText.")
    }

    func testSplitUnterminatedFenceIsNotFrontMatter() {
        // An opening `---` with no closing fence must not be treated as metadata.
        let text = "---\ntitle: X\n\n# Body without a closing fence"
        let (fm, _) = FrontMatter.split(text)
        XCTAssertNil(fm)
    }

    func testBodyStripsFrontMatter() {
        XCTAssertFalse(FrontMatter.body(note).contains("tags:"))
        XCTAssertTrue(FrontMatter.body(note).contains("must not be parsed"))
    }

    // MARK: field

    func testFieldReadsScalarFromFrontMatterOnly() {
        XCTAssertEqual(FrontMatter.field("customer", in: note), "Globex")
    }

    func testFieldIgnoresBodyColonLines() {
        // "title:" appears in the body too; field() only scans the FM block, and
        // the FM title value is quoted — proving it read the metadata line.
        XCTAssertEqual(FrontMatter.field("title", in: note), "\"Acme: Q3 Review\"")
    }

    func testFieldAbsentReturnsNil() {
        XCTAssertNil(FrontMatter.field("project", in: note))
    }

    // MARK: title

    func testTitleStripsSurroundingQuotes() {
        XCTAssertEqual(FrontMatter.title(in: note), "Acme: Q3 Review")
    }

    func testTitleEmptyOrAbsentReturnsNil() {
        XCTAssertNil(FrontMatter.title(in: "---\ntitle: \"\"\n---\nbody"))
        XCTAssertNil(FrontMatter.title(in: "# no front matter"))
    }

    // MARK: tags

    func testTagsParsedTrimmedAndFiltered() {
        XCTAssertEqual(FrontMatter.tags(in: note), ["meeting", "ghostwriter", "acme"])
    }

    func testTagsEmptyWhenNoTagsLine() {
        XCTAssertEqual(FrontMatter.tags(in: "---\ntitle: X\n---\nbody"), [])
    }

    func testTagsHandlesExtraSpacingAndTrailingCommas() {
        let t = FrontMatter.tags(in: "---\ntags: [ a ,  b ,, c , ]\n---\nbody")
        XCTAssertEqual(t, ["a", "b", "c"])
    }

    // MARK: yamlScalar

    func testYamlScalarLeavesPlainValueUnquoted() {
        XCTAssertEqual(FrontMatter.yamlScalar("customerCall"), "customerCall")
    }

    func testYamlScalarQuotesSignificantChars() {
        XCTAssertEqual(FrontMatter.yamlScalar("a: b [c]"), "\"a: b [c]\"")
    }

    func testYamlScalarDowngradesDoubleQuotesToSingle() {
        XCTAssertEqual(FrontMatter.yamlScalar("The \"Big\": Deal"), "\"The 'Big': Deal\"")
    }

    func testYamlScalarQuotesLeadingSpaceByDefault() {
        XCTAssertEqual(FrontMatter.yamlScalar(" leading"), "\" leading\"")
    }
}
