import Foundation
import Accelerate

// MARK: - Voice Activity Detector

/// Stateless local noise-gate helper — pure RMS/dBFS math, no network calls
/// or ML models. Callers compare the returned dBFS against their own threshold
/// and apply their own debounce (see the meeting audio callbacks).
final class VoiceActivityDetector {

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

    /// True if any short window of this 16-bit PCM blob rises above `threshold`
    /// dBFS. Scans in ~100 ms windows so a single spoken word inside a long,
    /// otherwise-silent recording is still detected (a whole-blob RMS would
    /// average it away). Used to skip uploading silent dictation to Groq.
    func containsVoice(in data: Data, aboveDBFS threshold: Float) -> Bool {
        let windowBytes = 3200  // 100 ms @ 16 kHz Int16 (1600 samples × 2 bytes)
        guard data.count >= MemoryLayout<Int16>.size else { return false }
        var offset = 0
        while offset < data.count {
            let end = min(offset + windowBytes, data.count)
            let window = data.subdata(in: offset..<end)
            if rmsToDBFS(calculateRMS(from: window)) >= threshold { return true }
            offset = end
        }
        return false
    }
}
