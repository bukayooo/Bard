import SwiftUI

struct SynthesisProgressView: View {
    let viewModel: JobViewModel

    var body: some View {
        VStack {
            Text("Generating Audiobook")
                .font(.bardDisplay(20, weight: .semibold))
                .padding(.top, 28)

            Spacer()

            VStack(spacing: 14) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 320)
                        .tint(BardTheme.terracotta)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.bardDisplay(28, weight: .semibold))
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
                    .padding(.top, 16)
            }

            Spacer()

            Button("Cancel", role: .destructive) {
                viewModel.cancelSynthesis()
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fraction: Double? {
        if case .synthesizing(_, let f) = viewModel.job.state { return f }
        return nil
    }
}
