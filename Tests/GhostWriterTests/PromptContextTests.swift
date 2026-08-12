import XCTest
@testable import GhostWriter

/// Unit tests for the self-priming transcription context — the pure logic that
/// decides what prompt hint Whisper (and the on-device fallback) receive.
/// Fixtures use neutral placeholder names (Acme, Globex, Initech…), not real data.
final class PromptContextTests: XCTestCase {

    // MARK: composePrompt (Whisper prompt hint)

    func testEmptyInputsProduceNoPrompt() {
        XCTAssertTrue(GroqService.composePrompt(vocabulary: "", context: "") == "")
        XCTAssertTrue(GroqService.composePrompt(vocabulary: "   ", context: "\n ") == "")
    }

    func testVocabularyOnly() {
        XCTAssertTrue(GroqService.composePrompt(vocabulary: "Glossary: Acme, Globex", context: "")
                == "Glossary: Acme, Globex")
    }

    func testContextOnly() {
        XCTAssertTrue(GroqService.composePrompt(vocabulary: "", context: "We compared Acme and Globex.")
                == "We compared Acme and Globex.")
    }

    /// Whisper attends most to the END of the prompt, so recent transcript must
    /// come last (closest to the new audio) and the glossary must lead.
    func testContextComesLastGlossaryLeads() {
        let p = GroqService.composePrompt(vocabulary: "Glossary: Acme",
                                          context: "Comparing Acme and Globex.")
        XCTAssertTrue(p.hasPrefix("Glossary: Acme"))
        XCTAssertTrue(p.hasSuffix("Comparing Acme and Globex."))
    }

    /// Only the most recent slice of context is kept — Whisper's prompt window
    /// is short, and unbounded context risks the model echoing the primer.
    func testContextCappedToRecentTail() {
        let long = String(repeating: "a", count: 300) + String(repeating: "b", count: 600)
        let p = GroqService.composePrompt(vocabulary: "", context: long)
        XCTAssertTrue(p.count == 500)
        XCTAssertTrue(p.hasSuffix(String(repeating: "b", count: 500)))
    }

    // MARK: contextualStrings (on-device recognition bias)

    func testContextualStringsCollectsGlossaryAndProperNouns() {
        let hints = OfflineTranscriber.contextualStrings(
            vocabulary: "Acme, API Gateway",
            context: "we should compare Globex and the gateway")
        XCTAssertTrue(hints.contains("Acme"))
        XCTAssertTrue(hints.contains("API Gateway"))
        XCTAssertTrue(hints.contains("Globex"))                                   // capitalized → proper-noun candidate
        XCTAssertTrue(!hints.contains(where: { $0.lowercased() == "gateway" }))    // lowercase → skipped
    }

    func testContextualStringsDeduplicatesCaseInsensitively() {
        let hints = OfflineTranscriber.contextualStrings(vocabulary: "Acme, acme",
                                                         context: "Acme again")
        XCTAssertTrue(hints.filter { $0.lowercased() == "acme" }.count == 1)
    }
}
