import SwiftUI

struct SynthesisProgressView: View {
    let viewModel: JobViewModel

    /// Cached (decoded once, keyed by filename) in SynthesisGIFLibrary, so this
    /// is cheap to recompute on every progress-driven body re-evaluation.
    private var gifPlayer: GIFPlayer? {
        SynthesisGIFLibrary.player(for: viewModel.synthesisGIFName)
    }

    /// The screen's background follows the GIF's own palette rather than the
    /// app's usual light/dark canvas, so foreground text/controls are picked by
    /// this color's own luminance instead of the system color scheme.
    private var backgroundColor: Color {
        gifPlayer?.averageColor ?? BardTheme.canvasBackground(.dark)
    }
    private var foregroundColor: Color {
        backgroundColor.isPerceptuallyDark ? BardTheme.parchment : BardTheme.charcoal
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Generating Audiobook")
                .font(.bardDisplay(20, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.top, 28)

            Spacer(minLength: 12)

            if let gifPlayer {
                AnimatedGIFView(player: gifPlayer, maxSize: CGSize(width: 440, height: 260))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(BardTheme.terracottaDeep.opacity(0.35), lineWidth: 1)
                    )
            }

            VStack(spacing: 14) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 320)
                        .tint(BardTheme.terracotta)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.bardDisplay(28, weight: .semibold))
                        .foregroundStyle(foregroundColor)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(BardTheme.terracotta)
                }
            }

            if let stallWarning = viewModel.stallWarning {
                Label(stallWarning, systemImage: "wifi.exclamationmark")
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .padding(10)
                    .frame(maxWidth: 480)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 12)

            Button("Cancel", role: .destructive) {
                viewModel.cancelSynthesis()
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .animation(.easeInOut(duration: 0.3), value: backgroundColor)
    }

    private var fraction: Double? {
        if case .synthesizing(_, let f) = viewModel.job.state { return f }
        return nil
    }
}
