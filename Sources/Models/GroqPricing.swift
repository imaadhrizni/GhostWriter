import Foundation

// MARK: - Groq Pricing
//
// The single place the Groq cost estimate is computed. Both the aggregate
// counters (UsageStats) and the per-call log (APIUsageLog) price the same way,
// using the editable rates in Settings — so a rate or unit change happens once
// and the two can never silently diverge.

enum GroqPricing {
    /// USD estimate for a chat/completion call's token usage.
    static func chatCost(inputTokens: Int, outputTokens: Int) -> Double {
        let s = AppSettings.shared
        return Double(inputTokens) / 1_000_000.0 * s.priceInputPerMTok
             + Double(outputTokens) / 1_000_000.0 * s.priceOutputPerMTok
    }

    /// USD estimate for transcribing `seconds` of audio.
    static func audioCost(seconds: Double) -> Double {
        seconds / 3600.0 * AppSettings.shared.priceAudioPerHour
    }
}
