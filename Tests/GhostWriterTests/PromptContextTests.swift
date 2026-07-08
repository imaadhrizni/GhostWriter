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

    @Test func contextualStringsIncludesExtraHarvestedTerms() {
        let hints = OfflineTranscriber.contextualStrings(
            vocabulary: "", context: "", extraTerms: ["Initech Corp", "ZENDA"])
        #expect(hints.contains("Initech Corp"))
        #expect(hints.contains("ZENDA"))
    }

    // MARK: MeetingVocabulary.extractTerms (auto-harvested glossary)

    @Test func extractPicksUpAcronymsAndProducts() {
        let notes = """
        We are migrating the ESB to ACME2. The RFP mentions ACME2 again.
        ZENDA is the incumbent. ACME2 wins on API management.
        """
        let terms = MeetingVocabulary.extractTerms(from: notes)
        #expect(terms.contains("ACME2"))
        #expect(terms.contains("ESB"))
        #expect(terms.contains("ZENDA"))
    }

    @Test func extractRanksFrequentTermsFirst() {
        let notes = "ACME2 ACME2 ACME2 handles the ESB migration once."
        let terms = MeetingVocabulary.extractTerms(from: notes)
        #expect(terms.first == "ACME2")   // most-mentioned leads
    }

    @Test func extractFiltersCommonAcronymNoise() {
        let terms = MeetingVocabulary.extractTerms(from: "OK so the ETA is fine, FYI.")
        #expect(!terms.contains("OK"))
        #expect(!terms.contains("ETA"))
        #expect(!terms.contains("FYI"))
    }

    @Test func extractHandlesEmptyText() {
        #expect(MeetingVocabulary.extractTerms(from: "").isEmpty)
    }

    // MARK: TextPolisher.glossaryDirective (shared with downstream summaries)

    @Test func glossaryDirectiveEmptyWhenNoTerms() {
        #expect(TextPolisher.glossaryDirective([]) == "")
        #expect(TextPolisher.glossaryDirective(["", "   "]) == "")
    }

    @Test func glossaryDirectiveListsTermsAndGuardsAgainstInvention() {
        let d = TextPolisher.glossaryDirective(["Acme", "Globex"])
        #expect(d.contains("Acme, Globex"))
        #expect(d.lowercased().contains("never introduce a term that was"))
    }

    @Test func glossaryDirectiveCapsAtForty() {
        let many = (1...60).map { "Term\($0)" }
        let d = TextPolisher.glossaryDirective(many)
        #expect(d.contains("Term40"))
        #expect(!d.contains("Term41"))
    }
}

/// Project scoping/inheritance — the pure operations over a project list.
/// Uses neutral placeholder buckets (Acme, Initech, MBA), not real data.
@Suite struct ProjectsTests {

    private var sample: [Project] {
        [
            Project(id: "acme", name: "Acme", parentID: nil, terms: ["Acme", "ESB"]),
            Project(id: "initech", name: "Initech", parentID: "acme", terms: ["Initech", "Dana"]),
            Project(id: "mba", name: "MBA", parentID: nil, terms: ["Porter", "NPV"])
        ]
    }

    @Test func topLevelExcludesChildren() {
        let tops = Projects.topLevel(in: sample).map(\.id)
        #expect(tops == ["acme", "mba"])
    }

    @Test func childrenOfParent() {
        #expect(Projects.children(of: "acme", in: sample).map(\.id) == ["initech"])
        #expect(Projects.children(of: "mba", in: sample).isEmpty)
    }

    @Test func lineageOfChildIncludesParent() {
        #expect(Projects.lineage(of: "initech", in: sample) == ["initech", "acme"])
        #expect(Projects.lineage(of: "acme", in: sample) == ["acme"])
    }

    @Test func displayPathShowsParent() {
        #expect(Projects.displayPath(of: "initech", in: sample) == "Acme › Initech")
        #expect(Projects.displayPath(of: "acme", in: sample) == "Acme")
    }

    /// A child inherits the parent's terms (its own first), and sibling terms
    /// never leak — the whole point of scoping.
    @Test func manualTermsInheritParentNotSiblings() {
        let terms = Projects.manualTerms(forID: "initech", in: sample)
        #expect(terms == ["Initech", "Dana", "Acme", "ESB"])
        #expect(!terms.contains("Porter"))    // MBA is a different bucket
    }

    @Test func brokenParentLinkResolvesToSelf() {
        let orphan = [Project(id: "x", name: "X", parentID: "missing", terms: ["Xterm"])]
        #expect(Projects.lineage(of: "x", in: orphan) == ["x"])
        #expect(Projects.manualTerms(forID: "x", in: orphan) == ["Xterm"])
    }
}
