import Foundation
import FoundationModels

// MARK: - Apple Intelligence (on-device LLM)

/// A thin wrapper over Apple's on-device language model (Foundation Models,
/// macOS 26+ on Apple-Intelligence-capable hardware). It powers two things:
///   • **Local-only mode** — which previously skipped every AI step — can now
///     summarize, extract action items, and draft on-device, fully offline.
///   • A **fallback** for the cloud summaries when Groq is unreachable or capped.
///
/// Everything is best-effort: `isAvailable` gates on both OS version and the
/// model's runtime state, and every generate call returns nil rather than
/// throwing so callers can degrade gracefully. Output carries a source footer
/// (see `TextPolisher`) so the user always knows it came from Apple, not Groq.
enum AppleIntelligence {

    /// True only when the OS is new enough AND the on-device model is ready
    /// (downloaded, device eligible, not disabled). Safe to call on any OS.
    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    /// A human-readable reason the model isn't usable, for Settings/diagnostics.
    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "Requires macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        case .unavailable:
            return "Apple Intelligence is unavailable."
        }
    }

    // MARK: Task helpers (mirror the Groq prompts, trimmed for a small model)

    /// A meeting summary with the template's sections and, optionally, action items.
    static func summarizeMeeting(transcript: String, sections: [String], includeActionItems: Bool) async -> String? {
        var asks = sections
        if includeActionItems {
            asks.append("A \"## Action Items\" section as a Markdown checklist ('- [ ] task'), or '_None_'.")
        }
        let instructions = """
        You summarize meeting transcripts into concise Markdown. Include these sections, in order, \
        each with its heading even when empty (write "_None_"):
        \(asks.joined(separator: "\n"))
        Use only what's in the transcript — never invent. Output only the Markdown.
        """
        return await generate(instructions: instructions, prompt: transcript)
    }

    /// One note's structured brief (mirrors `TextPolisher.noteBrief`) — the
    /// single artifact rendered as both the summary and the relationship digest.
    static func noteBrief(text: String) async -> String? {
        let instructions = """
        Summarize ONE note into this template, every bullet starting with "- ":
        - 3–6 summary bullets
        Next Steps
        - up to 3 (use "- None" if none)
        Action Items
        - up to 3 (use "- None" if none)
        Keep the labels "Next Steps" and "Action Items" on their own lines. No title/heading. \
        Use only this note. Output only the template.
        """
        return await generate(instructions: instructions, prompt: text)
    }

    /// A follow-up draft from a meeting's notes.
    static func draftFollowUp(notes: String, guidance: String) async -> String? {
        let instructions = """
        Draft a follow-up from these meeting notes. \(guidance)
        Use only what's in the notes — never invent. Keep it tight and skimmable. \
        If it's an email, start with a one-line subject. Output the follow-up only.
        """
        return await generate(instructions: instructions, prompt: notes)
    }

    // MARK: Core

    /// Generate a response on-device, or nil if unavailable/failed. Input is
    /// clipped to keep well within the small on-device context window.
    static func generate(instructions: String, prompt: String) async -> String? {
        guard #available(macOS 26.0, *), isAvailable else { return nil }
        let clipped = String(prompt.suffix(6_000))
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: clipped)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            Log.api.warning("⚠️ Apple Intelligence generation failed: \(error.localizedDescription)")
            return nil
        }
    }
}
