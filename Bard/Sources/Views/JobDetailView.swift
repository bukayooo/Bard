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

    /// The first line reads as a normal sentence ("epub2tts-edge exited with code
    /// 9."); everything after it is raw tool output (tqdm bars, tracebacks) that
    /// reads far better in a capped-width, monospaced, scrollable box than as
    /// centered proportional-font body text stretching across the whole window.
    private var headline: String { message.components(separatedBy: "\n").first ?? message }
    private var details: [String] {
        let lines = message.components(separatedBy: "\n")
        return lines.count > 1 ? Array(lines.dropFirst()) : []
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 20)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.bardDisplay(19))
            Text(headline)
                .font(.system(.body, design: .serif))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if !details.isEmpty {
                LogView(lines: details)
                    .frame(maxWidth: 640, maxHeight: 260)
            }
            Spacer(minLength: 20)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
