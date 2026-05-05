import Foundation
import Accelerate

// MARK: - Voice Activity Detector

/// Simple local noise-gate VAD to prevent sending dead air to Groq.
/// Uses RMS energy threshold — no network calls, no ML models, pure math.
///
/// Algorithm:
/// 1. Calculate RMS of each audio buffer frame
/// 2. Convert to dBFS: 20 * log10(rms)
/// 3. If above threshold → voice active
/// 4. If below threshold for > debounce duration → voice inactive
final class VoiceActivityDetector {

    // MARK: - Configuration

    /// Threshold in dBFS. Typical quiet room is ~-50 dBFS, speech is ~-20 dBFS.
    var thresholdDBFS: Float = -40.0

    /// How long silence must persist before we consider voice inactive (seconds).
    var silenceDebounce: TimeInterval = 0.3

    // MARK: - State

    private var lastVoiceTime: Date?
    private var _isActive = false

    var isActive: Bool { _isActive }

    // MARK: - RMS Calculation

    /// Calculate RMS (Root Mean Square) of 16-bit PCM audio data.
    /// Returns a value between 0.0 and 1.0.
    func calculateRMS(from data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0.0 }

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return Float(0.0) }
            let samples = baseAddress.assumingMemoryBound(to: Int16.self)

            var sumSquares: Float = 0.0

            // Use Accelerate for performance
            var floatSamples = [Float](repeating: 0, count: sampleCount)
            vDSP_vflt16(samples, 1, &floatSamples, 1, vDSP_Length(sampleCount))

            // Normalize to -1.0...1.0
            var divisor = Float(Int16.max)
            vDSP_vsdiv(floatSamples, 1, &divisor, &floatSamples, 1, vDSP_Length(sampleCount))

            // Calculate mean square
            vDSP_measqv(floatSamples, 1, &sumSquares, vDSP_Length(sampleCount))

            return sqrtf(sumSquares)
        }
    }

    /// Convert RMS to dBFS (decibels relative to full scale).
    func rmsToDBFS(_ rms: Float) -> Float {
        guard rms > 0 else { return -Float.infinity }
        return 20.0 * log10f(rms)
    }

    /// Check if the current audio buffer contains voice activity.
    /// Handles debounce logic internally.
    func isVoiceActive(rms: Float) -> Bool {
        let dbfs = rmsToDBFS(rms)

        if dbfs >= thresholdDBFS {
            // Voice detected
            lastVoiceTime = Date()
            _isActive = true
            return true
        } else {
            // Below threshold — check debounce
            if let lastVoice = lastVoiceTime,
               Date().timeIntervalSince(lastVoice) < silenceDebounce {
                // Still within debounce window — keep active
                return true
            }

            _isActive = false
            return false
        }
    }

    /// Reset the VAD state.
    func reset() {
        lastVoiceTime = nil
        _isActive = false
    }
}
