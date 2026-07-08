import Testing
@testable import GhostWriter

/// Unit tests for the self-priming transcription context — the pure logic that
/// decides what prompt hint Whisper (and the on-device fallback) receive.
@Suite struct PromptContextTests {

    // MARK: composePrompt (Whisper prompt hint)

    @Test func emptyInputsProduceNoPrompt() {
        #expect(GroqService.composePrompt(vocabulary: "", context: "") == "")
        #expect(GroqService.composePrompt(vocabulary: "   ", context: "\n ") == "")
    }

    @Test func vocabularyOnly() {
        #expect(GroqService.composePrompt(vocabulary: "Glossary: WSO2, Fiorano", context: "")
                == "Glossary: WSO2, Fiorano")
    }

    @Test func contextOnly() {
        #expect(GroqService.composePrompt(vocabulary: "", context: "We compared WSO2 and Fiorano.")
                == "We compared WSO2 and Fiorano.")
    }

    /// Whisper attends most to the END of the prompt, so recent transcript must
    /// come last (closest to the new audio) and the glossary must lead.
    @Test func contextComesLastGlossaryLeads() {
        let p = GroqService.composePrompt(vocabulary: "Glossary: WSO2",
                                          context: "Comparing WSO2 and Fiorano.")
        #expect(p.hasPrefix("Glossary: WSO2"))
        #expect(p.hasSuffix("Comparing WSO2 and Fiorano."))
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
            vocabulary: "WSO2, API Gateway",
            context: "we should compare Fiorano and the gateway")
        #expect(hints.contains("WSO2"))
        #expect(hints.contains("API Gateway"))
        #expect(hints.contains("Fiorano"))                                   // capitalized → proper-noun candidate
        #expect(!hints.contains(where: { $0.lowercased() == "gateway" }))    // lowercase → skipped
    }

    @Test func contextualStringsDeduplicatesCaseInsensitively() {
        let hints = OfflineTranscriber.contextualStrings(vocabulary: "WSO2, wso2",
                                                         context: "WSO2 again")
        #expect(hints.filter { $0.lowercased() == "wso2" }.count == 1)
    }

    @Test func contextualStringsIncludesExtraHarvestedTerms() {
        let hints = OfflineTranscriber.contextualStrings(
            vocabulary: "", context: "", extraTerms: ["Zain Iraq", "TIBCO"])
        #expect(hints.contains("Zain Iraq"))
        #expect(hints.contains("TIBCO"))
    }

    // MARK: MeetingVocabulary.extractTerms (auto-harvested glossary)

    @Test func extractPicksUpAcronymsAndProducts() {
        let notes = """
        We are migrating the ESB to WSO2. The RFP mentions WSO2 again.
        TIBCO is the incumbent. WSO2 wins on API management.
        """
        let terms = MeetingVocabulary.extractTerms(from: notes)
        #expect(terms.contains("WSO2"))
        #expect(terms.contains("ESB"))
        #expect(terms.contains("TIBCO"))
    }

    @Test func extractRanksFrequentTermsFirst() {
        let notes = "WSO2 WSO2 WSO2 handles the ESB migration once."
        let terms = MeetingVocabulary.extractTerms(from: notes)
        #expect(terms.first == "WSO2")   // most-mentioned leads
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
}

/// Project scoping/inheritance — the pure operations over a project list.
@Suite struct ProjectsTests {

    private var sample: [Project] {
        [
            Project(id: "wso2", name: "WSO2", parentID: nil, terms: ["WSO2", "ESB"]),
            Project(id: "zain", name: "Zain Iraq", parentID: "wso2", terms: ["Zain Iraq", "Muazzam"]),
            Project(id: "mba", name: "MBA", parentID: nil, terms: ["Porter", "NPV"])
        ]
    }

    @Test func topLevelExcludesChildren() {
        let tops = Projects.topLevel(in: sample).map(\.id)
        #expect(tops == ["wso2", "mba"])
    }

    @Test func childrenOfParent() {
        #expect(Projects.children(of: "wso2", in: sample).map(\.id) == ["zain"])
        #expect(Projects.children(of: "mba", in: sample).isEmpty)
    }

    @Test func lineageOfChildIncludesParent() {
        #expect(Projects.lineage(of: "zain", in: sample) == ["zain", "wso2"])
        #expect(Projects.lineage(of: "wso2", in: sample) == ["wso2"])
    }

    @Test func displayPathShowsParent() {
        #expect(Projects.displayPath(of: "zain", in: sample) == "WSO2 › Zain Iraq")
        #expect(Projects.displayPath(of: "wso2", in: sample) == "WSO2")
    }

    /// A child inherits the parent's terms (its own first), and sibling terms
    /// never leak — the whole point of scoping.
    @Test func manualTermsInheritParentNotSiblings() {
        let terms = Projects.manualTerms(forID: "zain", in: sample)
        #expect(terms == ["Zain Iraq", "Muazzam", "WSO2", "ESB"])
        #expect(!terms.contains("Porter"))    // MBA is a different bucket
    }

    @Test func brokenParentLinkResolvesToSelf() {
        let orphan = [Project(id: "x", name: "X", parentID: "missing", terms: ["Xterm"])]
        #expect(Projects.lineage(of: "x", in: orphan) == ["x"])
        #expect(Projects.manualTerms(forID: "x", in: orphan) == ["Xterm"])
    }
}
