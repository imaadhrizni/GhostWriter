import SwiftUI

/// The floating visual indicator for Voiceeee.
/// Shows recording state with pulsing animations and audio level visualization.
struct GlowOverlayView: View {
    let state: AppState

    var body: some View {
        ZStack {
            switch state.recordingState {
            case .idle:
                EmptyView()

            case .listening:
                ListeningView(audioLevel: state.audioLevel)

            case .processing:
                ProcessingView()

            case .done:
                DoneView()

            case .error(let message):
                ErrorView(message: message)
            }
        }
        .frame(width: 180, height: 180)
        .animation(.easeInOut(duration: 0.3), value: state.recordingState)
    }
}

// MARK: - Listening State

private struct ListeningView: View {
    let audioLevel: Float

    @State private var isPulsing = false

    private var normalizedLevel: CGFloat {
        CGFloat(min(max(audioLevel * 5, 0.3), 1.0))
    }

    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.cyan.opacity(0.6 * normalizedLevel),
                            Color.blue.opacity(0.3 * normalizedLevel),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 80
                    )
                )
                .scaleEffect(isPulsing ? 1.1 : 0.9)

            // Inner core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.9),
                            Color.cyan.opacity(0.7),
                            Color.blue.opacity(0.4)
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 30
                    )
                )
                .frame(width: 40 * normalizedLevel + 20, height: 40 * normalizedLevel + 20)

            // Waveform icon
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Processing State

private struct ProcessingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Spinning ring
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.cyan, .blue, .purple, .cyan],
                        center: .center
                    ),
                    lineWidth: 3
                )
                .frame(width: 60, height: 60)
                .rotationEffect(.degrees(rotation))

            // Glow background
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.purple.opacity(0.3),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 70
                    )
                )

            // Processing icon
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Done State

private struct DoneView: View {
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.green.opacity(0.6),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 60
                    )
                )

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.green)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                scale = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                opacity = 0.0
            }
        }
    }
}

// MARK: - Error State

private struct ErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)

            Text(message)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.7))
        )
    }
}
