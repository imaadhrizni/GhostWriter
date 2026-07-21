import Foundation

// MARK: - Voice Identity Store

/// Persistent, named voice fingerprints so recurring speakers are recognized
/// across meetings — turning "Them 2" into "Priya" automatically, and linking
/// that voice to the real person in the Catalog.
///
/// Two things live here:
///   • **identities** — the voice profiles you've taught (by renaming a
///     speaker to a Catalog person), matched against each new meeting's
///     diarized voices. Each carries the `personID` of the Catalog person it
///     belongs to (the durable link) plus a cached `name` for glossary priming.
///   • **snapshots** — a small, bounded cache of the per-meeting voice
///     fingerprints (keyed by notes-file path) so a rename done *later* can
///     still learn which fingerprint the new name belongs to.
///
/// Fingerprints are the same lightweight (pitch, ZCR) features the
/// `SpeakerProfiler` clusters on. Stored in Application Support (rebuildable —
/// excluded from backups); the durable person is in the Catalog, so a lost
/// store just means voices are re-taught, never people lost.
final class VoiceIdentityStore {
    static let shared = VoiceIdentityStore()

    struct Identity: Codable {
        var name: String
        var pitch: Float
        var zcr: Float
        /// The Catalog person this voice belongs to. Optional so voices taught
        /// before Catalog-linking (or by name only) still decode and match.
        var personID: String?
    }
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

    /// The saved identity closest to this fingerprint, or nil when none is
    /// close enough — carries both the display name and the linked `personID`.
    func matchIdentity(pitch: Float, zcr: Float) -> Identity? {
        queue.sync {
            var best: (id: Identity, d: Float)? = nil
            for id in model.identities {
                let d = Self.distance(pitch, zcr, id.pitch, id.zcr)
                if d < Self.matchThreshold, best == nil || d < best!.d { best = (id, d) }
            }
            return best?.id
        }
    }

    /// The name of the saved identity closest to this fingerprint, or nil when
    /// none is close enough. (Convenience over `matchIdentity`.)
    func match(pitch: Float, zcr: Float) -> String? {
        matchIdentity(pitch: pitch, zcr: zcr)?.name
    }

    /// Every saved identity name — used to prime transcription with the people
    /// you've taught, so Whisper spells them right.
    var knownNames: [String] {
        queue.sync { model.identities.map(\.name) }
    }

    /// Whether a Catalog person has a taught voice profile — for the person
    /// editor's "recognized voice" status.
    func hasVoice(personID: String) -> Bool {
        queue.sync { model.identities.contains { $0.personID == personID } }
    }

    // MARK: Teaching

    /// Save (or refine, via EMA) a voice identity from a fingerprint, linked to
    /// a Catalog person. When `personID` is given it is the match key (so a
    /// person renamed in the Catalog keeps one profile); otherwise we fall back
    /// to matching by name. A legacy name-only identity is adopted (gains the
    /// `personID`) rather than duplicated.
    func remember(name: String, pitch: Float, zcr: Float, personID: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, pitch > 0 else { return }
        queue.sync {
            let i = model.identities.firstIndex {
                if let personID { return $0.personID == personID }
                return $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            } ?? model.identities.firstIndex {
                // Adopt a matching name-only profile when linking for the first time.
                personID != nil && $0.personID == nil
                    && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }
            if let i {
                let a: Float = 0.4
                model.identities[i].pitch = model.identities[i].pitch * (1 - a) + pitch * a
                model.identities[i].zcr   = model.identities[i].zcr   * (1 - a) + zcr   * a
                model.identities[i].name  = trimmed
                if let personID { model.identities[i].personID = personID }
            } else {
                model.identities.append(Identity(name: trimmed, pitch: pitch, zcr: zcr, personID: personID))
            }
            persist()
        }
    }

    /// Forget the voice profile(s) linked to a Catalog person (the person
    /// editor's "Forget voice", and cleanup when a person is deleted).
    func forget(personID: String) {
        queue.sync {
            let before = model.identities.count
            model.identities.removeAll { $0.personID == personID }
            if model.identities.count != before { persist() }
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
