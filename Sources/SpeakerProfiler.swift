import Foundation
import Accelerate

// MARK: - Speaker Profiler
//
// Voice-based differentiation of remote speakers in Meeting Mode.
// For each speech segment it extracts a small voice fingerprint —
//   • median pitch (fundamental frequency via autocorrelation)
//   • brightness (zero-crossing rate, a cheap spectral-centroid proxy)
//   • loudness (dBFS)
// — and clusters segments: a new segment is assigned to the closest known
// speaker profile, or opens a new one when no profile is close enough.
//
// This is lightweight, fully on-device, and works on 16 kHz mono Int16 PCM.
// It is *not* neural speaker embedding — same-pitched voices can merge —
// but it distinguishes typically different voices (e.g. higher vs lower
// registers) far better than a pause/loudness toggle.
//
// Not thread-safe by itself; call only from the meeting processing queue.
final class SpeakerProfiler {

    private struct Profile {
        var pitch: Float        // running average, Hz
        var zcr: Float          // running average, crossings per sample (0…1)
        var dbfs: Float         // running average loudness
        var segments: Int       // how many segments matched this profile
    }

    private var profiles: [Profile] = []
    private let sampleRate: Float = 16_000
    private let maxSpeakers = 4

    /// Start fresh for a new meeting.
    func reset() {
        profiles.removeAll()
    }

    /// Returns "Them", "Them 2", … for the voice in this segment.
    func label(for audio: Data) -> String {
        guard let features = extractFeatures(from: audio) else {
            // Unpitched/too-short segment — attribute to the current speaker.
            return labelForIndex(max(profiles.count - 1, 0))
        }

        // Find the closest existing profile.
        var bestIndex = -1
        var bestDistance = Float.greatestFiniteMagnitude
        for (i, p) in profiles.enumerated() {
            let d = distance(from: features, to: p)
            if d < bestDistance { bestDistance = d; bestIndex = i }
        }

        // Distance threshold: below it, same voice; above it, a new speaker.
        // Pitch dominates the metric (see distance(from:to:)) — ~2.5 semitones
        // of sustained pitch difference is enough to split.
        let threshold: Float = 1.0

        if bestIndex >= 0 && (bestDistance < threshold || profiles.count >= maxSpeakers) {
            update(profileAt: bestIndex, with: features)
            return labelForIndex(bestIndex)
        }

        profiles.append(Profile(pitch: features.pitch, zcr: features.zcr,
                                dbfs: features.dbfs, segments: 1))
        return labelForIndex(profiles.count - 1)
    }

    private func labelForIndex(_ i: Int) -> String {
        i <= 0 ? "Them" : "Them \(i + 1)"
    }

    // MARK: - Clustering

    private func distance(from f: (pitch: Float, zcr: Float, dbfs: Float), to p: Profile) -> Float {
        // Pitch difference in semitones — perceptually meaningful and
        // speaker-characteristic. 12 * log2(f1/f2).
        let semitones = abs(12 * log2f(f.pitch / p.pitch))
        // ZCR difference, scaled so a large timbre change ≈ 1.0.
        let zcrDiff = abs(f.zcr - p.zcr) / 0.15
        // Weighted: 2.5 semitones alone crosses the 1.0 threshold.
        return semitones / 2.5 + zcrDiff * 0.35
    }

    private func update(profileAt i: Int, with f: (pitch: Float, zcr: Float, dbfs: Float)) {
        // Exponential moving average so a speaker's profile tracks slow drift
        // without being yanked around by one odd segment.
        let alpha: Float = 0.3
        profiles[i].pitch = profiles[i].pitch * (1 - alpha) + f.pitch * alpha
        profiles[i].zcr   = profiles[i].zcr   * (1 - alpha) + f.zcr   * alpha
        profiles[i].dbfs  = profiles[i].dbfs  * (1 - alpha) + f.dbfs  * alpha
        profiles[i].segments += 1
    }

    // MARK: - Feature extraction

    /// Median pitch + ZCR + loudness across the voiced frames of the segment.
    /// Returns nil when the segment has no reliably pitched frames.
    private func extractFeatures(from audio: Data) -> (pitch: Float, zcr: Float, dbfs: Float)? {
        let samples: [Float] = audio.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            return int16.map { Float($0) / 32768.0 }
        }

        let frameSize = 800      // 50 ms at 16 kHz — enough for 80 Hz pitch
        let hop = 400
        guard samples.count >= frameSize else { return nil }

        var pitches: [Float] = []
        var zcrs: [Float] = []
        var rmsTotal: Float = 0
        var frames = 0

        var start = 0
        while start + frameSize <= samples.count {
            let frame = Array(samples[start ..< start + frameSize])
            start += hop
            frames += 1

            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frameSize))
            rmsTotal += rms

            // Skip quiet frames — pitch from silence is noise.
            guard rms > 0.01 else { continue }

            if let pitch = pitchOf(frame: frame) {
                pitches.append(pitch)
                zcrs.append(zeroCrossingRate(of: frame))
            }
        }

        // Require a handful of voiced frames for a trustworthy fingerprint.
        guard pitches.count >= 5 else { return nil }

        let medianPitch = pitches.sorted()[pitches.count / 2]
        let meanZCR = zcrs.reduce(0, +) / Float(zcrs.count)
        let meanRMS = frames > 0 ? rmsTotal / Float(frames) : 0
        let dbfs = 20 * log10f(max(meanRMS, 1e-9))
        return (medianPitch, meanZCR, dbfs)
    }

    /// Fundamental frequency of one frame via time-domain autocorrelation,
    /// searched over the human-voice range 70–350 Hz. Returns nil when the
    /// frame is not clearly periodic (unvoiced consonants, noise, music).
    private func pitchOf(frame: [Float]) -> Float? {
        let minLag = Int(sampleRate / 350)   // ~46 samples
        let maxLag = Int(sampleRate / 70)    // ~229 samples
        guard frame.count > maxLag else { return nil }

        var energy: Float = 0
        vDSP_dotpr(frame, 1, frame, 1, &energy, vDSP_Length(frame.count))
        guard energy > 0 else { return nil }

        var bestLag = 0
        var bestCorr: Float = 0
        for lag in minLag...maxLag {
            var corr: Float = 0
            vDSP_dotpr(frame, 1, Array(frame[lag...]), 1, &corr, vDSP_Length(frame.count - lag))
            if corr > bestCorr { bestCorr = corr; bestLag = lag }
        }

        // Normalized autocorrelation peak must be strong to count as voiced.
        guard bestLag > 0, bestCorr / energy > 0.45 else { return nil }
        return sampleRate / Float(bestLag)
    }

    private func zeroCrossingRate(of frame: [Float]) -> Float {
        var crossings = 0
        for i in 1 ..< frame.count where (frame[i - 1] < 0) != (frame[i] < 0) {
            crossings += 1
        }
        return Float(crossings) / Float(frame.count)
    }
}
