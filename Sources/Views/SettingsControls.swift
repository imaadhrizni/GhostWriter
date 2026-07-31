import SwiftUI

// MARK: - Reusable Settings Controls
//
// Shared, leaf-level building blocks used across every Settings pane. Kept in
// their own file so the pane views can live in separate files too (they are
// `internal`, not `private`, precisely so those split-out panes can reach them).

/// A multi-line text box with a greyed placeholder shown while it's empty —
/// SwiftUI's `TextEditor` has no prompt of its own, so an empty field otherwise
/// reads as a broken blank box. Centralizes the monospaced font + border styling
/// every settings editor was hand-rolling. Grows past `minHeight` as text wraps.
struct MultilineField: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 54
    var font: Font = .system(.caption, design: .monospaced)

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .frame(minHeight: minHeight)
            // Placeholder sits on top but only while empty (so it never covers
            // real text) and ignores hits so clicks fall through to the editor.
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }
}

/// Card-style settings group with a header, mimicking System Settings.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
}

/// Slider for dBFS thresholds with a live value readout and a reset-to-default button.
struct ThresholdSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f dBFS", value))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                DefaultResetButton(isDefault: value == defaultValue) { value = defaultValue }
            }
            Slider(value: $value, in: range, step: 1)
            if let help {
                Text(help).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

/// Slider for durations (seconds) with a live value readout and a reset button.
struct DurationSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let defaultValue: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f %@", value, unit))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                DefaultResetButton(isDefault: value == defaultValue) { value = defaultValue }
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

/// Small circular-arrow button, disabled when the value already matches the default.
struct DefaultResetButton: View {
    let isDefault: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(isDefault)
        .help("Reset to default")
    }
}

/// Full-width row with a destructive "Reset All Settings…" action + confirm.
struct ResetToDefaultsRow: View {
    @State private var confirming = false

    var body: some View {
        HStack {
            Text("Restore every setting to its default value.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Reset All Settings…", role: .destructive) { confirming = true }
                .confirmationDialog("Reset all settings to defaults?", isPresented: $confirming) {
                    Button("Reset", role: .destructive) {
                        AppSettings.shared.resetToDefaults()
                        NotificationCenter.default.post(name: .settingsDidReset, object: nil)
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }
}
