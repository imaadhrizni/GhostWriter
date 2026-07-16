import SwiftUI

// MARK: - POC status / phase → presentation
//
// One source of truth for the colours and glyphs used across the POC tracker,
// its detail pane, the Reports charts, and the PDF export. Previously each of
// these defined its own `statusColor` / `statusIcon` / `pocPhaseTint` /
// `ReportPalette.phase` with subtly different values — unified here.

extension PocStatus {
    /// Tint for a criterion's pass/fail/pending state.
    var color: Color {
        switch self { case .pass: .green; case .fail: .red; case .pending: .secondary }
    }
    /// SF Symbol for a criterion's state (consistent circle family).
    var icon: String {
        switch self {
        case .pass:    "checkmark.circle.fill"
        case .fail:    "xmark.circle.fill"
        case .pending: "circle"
        }
    }
}

extension PocPhase {
    /// Tint for a POC lifecycle phase — used by tracker rows, the phase pill,
    /// Reports charts, and the PDF.
    var tint: Color {
        switch self {
        case .planned: .gray
        case .active:  .blue
        case .passed:  .green
        case .failed:  .red
        case .onHold:  .orange
        }
    }
}
