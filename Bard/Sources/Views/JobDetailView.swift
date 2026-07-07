import SwiftUI

struct JobDetailView: View {
    @Bindable var viewModel: JobViewModel

    var body: some View {
        Group {
            switch viewModel.job.state {
            case .idle, .extracting:
                ExtractionProgressView(viewModel: viewModel)
            case .readyForReview:
                ReviewView(viewModel: viewModel)
            case .synthesizing:
                SynthesisProgressView(viewModel: viewModel)
            case .done:
                DoneView(viewModel: viewModel)
            case .failed(let message):
                FailedView(message: message)
            }
        }
        .navigationTitle(
            viewModel.job.title.isEmpty
                ? viewModel.job.originalURL.lastPathComponent : viewModel.job.title)
    }
}

private struct FailedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.title2)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 40)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
