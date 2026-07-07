import SwiftUI

struct SynthesisProgressView: View {
    let viewModel: JobViewModel

    var body: some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 320)
                Text("\(Int(fraction * 100))%")
                    .font(.title3)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text("Generating audiobook…")
                .font(.title3)
            if !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            LogView(lines: viewModel.job.log)
                .frame(maxHeight: 220)
            Button("Cancel", role: .destructive) {
                viewModel.cancelSynthesis()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fraction: Double? {
        if case .synthesizing(_, let f) = viewModel.job.state { return f }
        return nil
    }

    private var detail: String {
        if case .synthesizing(let d, _) = viewModel.job.state { return d }
        return ""
    }
}
