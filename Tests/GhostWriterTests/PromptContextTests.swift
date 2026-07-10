import Testing
@testable import GhostWriter

/// Unit tests for the self-priming transcription context — the pure logic that
/// decides what prompt hint Whisper (and the on-device fallback) receive.
/// Fixtures use neutral placeholder names (Acme, Globex, Initech…), not real data.
@Suite struct PromptContextTests {

    // MARK: composePrompt (Whisper prompt hint)

    @Test func emptyInputsProduceNoPrompt() {
        #expect(GroqService.composePrompt(vocabulary: "", context: "") == "")
        #expect(GroqService.composePrompt(vocabulary: "   ", context: "\n ") == "")
    }

    @Test func vocabularyOnly() {
        #expect(GroqService.composePrompt(vocabulary: "Glossary: Acme, Globex", context: "")
                == "Glossary: Acme, Globex")
    }

    @Test func contextOnly() {
        #expect(GroqService.composePrompt(vocabulary: "", context: "We compared Acme and Globex.")
                == "We compared Acme and Globex.")
    }

    /// Whisper attends most to the END of the prompt, so recent transcript must
    /// come last (closest to the new audio) and the glossary must lead.
    @Test func contextComesLastGlossaryLeads() {
        let p = GroqService.composePrompt(vocabulary: "Glossary: Acme",
                                          context: "Comparing Acme and Globex.")
        #expect(p.hasPrefix("Glossary: Acme"))
        #expect(p.hasSuffix("Comparing Acme and Globex."))
    }

    /// Only the most recent slice of context is kept — Whisper's prompt window
    /// is short, and unbounded context risks the model echoing the primer.
    @Test func contextCappedToRecentTail() {
        let long = String(repeating: "a", count: 300) + String(repeating: "b", count: 600)
        let p = GroqService.composePrompt(vocabulary: "", context: long)
        #expect(p.count == 500)
        #expect(p.hasSuffix(String(repeating: "b", count: 500)))
    }

    // MARK: contextualStrings (on-device recognition bias)

    @Test func contextualStringsCollectsGlossaryAndProperNouns() {
        let hints = OfflineTranscriber.contextualStrings(
            vocabulary: "Acme, API Gateway",
            context: "we should compare Globex and the gateway")
        #expect(hints.contains("Acme"))
        #expect(hints.contains("API Gateway"))
        #expect(hints.contains("Globex"))                                   // capitalized → proper-noun candidate
        #expect(!hints.contains(where: { $0.lowercased() == "gateway" }))    // lowercase → skipped
    }

    @Test func contextualStringsDeduplicatesCaseInsensitively() {
        let hints = OfflineTranscriber.contextualStrings(vocabulary: "Acme, acme",
                                                         context: "Acme again")
        #expect(hints.filter { $0.lowercased() == "acme" }.count == 1)
    }
}
