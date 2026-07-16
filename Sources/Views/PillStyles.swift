import SwiftUI

// MARK: - Shared pill / chip / badge styling
//
// One place for the tinted-capsule look repeated across the app. Call sites keep
// their own content, font, and foreground colour; this factors out the identical
// `.padding().background(Capsule().fill(tint.opacity()))` boilerplate that was
// duplicated in ~a dozen little views. Padding/opacity are parameters so each
// site keeps its exact appearance.

extension View {
    /// Wrap content in the shared tinted-capsule background.
    func pillBackground(_ tint: Color, opacity: Double = 0.12,
                        hPad: CGFloat = 8, vPad: CGFloat = 3,
                        stroke: Double = 0) -> some View {
        self.padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(Capsule().fill(tint.opacity(opacity)))
            .overlay { if stroke > 0 { Capsule().stroke(tint.opacity(stroke)) } }
    }
}

/// A tinted text capsule — relationship/stage badges, note-list status chips,
/// phase tags, count pills. (Variants with a leading icon or a trailing remove
/// button build their own `HStack` and apply `.pillBackground` directly.)
struct TintedPill: View {
    let text: String
    var tint: Color = .blue
    var font: Font = .caption2
    var weight: Font.Weight = .medium
    var opacity: Double = 0.16
    var hPad: CGFloat = 6
    var vPad: CGFloat = 1
    var body: some View {
        Text(text).font(font).fontWeight(weight)
            .foregroundStyle(tint)
            .pillBackground(tint, opacity: opacity, hPad: hPad, vPad: vPad)
    }
}

/// A compact stat pill — icon · value · label in a tinted capsule. Shared by the
/// POC tracker and Keyword Radar stats strips (previously identical copies).
struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(tint)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .pillBackground(tint, opacity: 0.12, hPad: 8, vPad: 4)
    }
}
