import Foundation

// MARK: - Voice Identity Store

/// Persistent, named voice fingerprints so recurring speakers are recognized
/// across meetings — turning "Them 2" into "Priya" automatically.
///
/// Two things live here:
///   • **identities** — the named voice profiles you've taught (by renaming a
///     speaker), matched against each new meeting's diarized voices.
///   • **snapshots** — a small, bounded cache of the per-meeting voice
///     fingerprints (keyed by notes-file path) so a rename done *later* can
///     still learn which fingerprint the new name belongs to.
///
/// Fingerprints are the same lightweight (pitch, ZCR) features the
/// `SpeakerProfiler` clusters on. Stored in Application Support (rebuildable —
/// excluded from backups).
final class VoiceIdentityStore {
    static let shared = VoiceIdentityStore()

    struct Identity: Codable { var name: String; var pitch: Float; var zcr: Float }
    struct Fingerprint: Codable { var label: String; var pitch: Float; var zcr: Float }

    private struct Model: Codable {
        var identities: [Identity] = []
        var snapshots: [String: [Fingerprint]] = [:]   // notes-file path → fingerprints
    }

    private let queue = DispatchQueue(label: "com.ghostwriter.voiceidentity")
    private var model = Model()
    private let url: URL
    private let maxSnapshots = 30

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GhostWriter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("VoiceIdentities.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Model.self, from: data) {
            model = decoded
        }
    }

    // MARK: Matching

    /// Distance threshold below which two fingerprints are the same voice.
    /// Mirrors `SpeakerProfiler`'s metric (≈2.5 semitones of pitch → 1.0).
    private static let matchThreshold: Float = 0.8

    private static func distance(_ aPitch: Float, _ aZcr: Float, _ bPitch: Float, _ bZcr: Float) -> Float {
        guard aPitch > 0, bPitch > 0 else { return .greatestFiniteMagnitude }
        let semitones = abs(12 * log2f(aPitch / bPitch))
        let zcrDiff = abs(aZcr - bZcr) / 0.15
        return semitones / 2.5 + zcrDiff * 0.35
    }

    /// The name of the saved identity closest to this fingerprint, or nil when
    /// none is close enough.
    func match(pitch: Float, zcr: Float) -> String? {
        queue.sync {
            var best: (name: String, d: Float)? = nil
            for id in model.identities {
                let d = Self.distance(pitch, zcr, id.pitch, id.zcr)
                if d < Self.matchThreshold, best == nil || d < best!.d { best = (id.name, d) }
            }
            return best?.name
        }
    }

    /// Every saved identity name — used to prime transcription with the people
    /// you've taught, so Whisper spells them right.
    var knownNames: [String] {
        queue.sync { model.identities.map(\.name) }
    }

    // MARK: Teaching

    /// Save (or refine, via EMA) a named identity from a fingerprint.
    func remember(name: String, pitch: Float, zcr: Float) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, pitch > 0 else { return }
        queue.sync {
            if let i = model.identities.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                let a: Float = 0.4
                model.identities[i].pitch = model.identities[i].pitch * (1 - a) + pitch * a
                model.identities[i].zcr   = model.identities[i].zcr   * (1 - a) + zcr   * a
            } else {
                model.identities.append(Identity(name: trimmed, pitch: pitch, zcr: zcr))
            }
            persist()
        }
    }

    // MARK: Per-meeting snapshot cache

    /// Cache a meeting's fingerprints so a later rename can learn from them.
    func cacheSnapshot(_ snaps: [(label: String, pitch: Float, zcr: Float)], forFile path: String) {
        guard !snaps.isEmpty else { return }
        queue.sync {
            model.snapshots[path] = snaps.map { Fingerprint(label: $0.label, pitch: $0.pitch, zcr: $0.zcr) }
            // Bound the cache — drop arbitrary oldest entries past the cap.
            if model.snapshots.count > maxSnapshots {
                for key in model.snapshots.keys.prefix(model.snapshots.count - maxSnapshots) {
                    model.snapshots.removeValue(forKey: key)
                }
            }
            persist()
        }
    }

    /// The fingerprint captured for a given speaker label in a given meeting.
    func fingerprint(forLabel label: String, file path: String) -> (pitch: Float, zcr: Float)? {
        queue.sync {
            guard let f = model.snapshots[path]?.first(where: { $0.label == label }) else { return nil }
            return (f.pitch, f.zcr)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(model) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
