import SwiftUI

struct ExtractionProgressView: View {
    let viewModel: JobViewModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(BardTheme.terracotta)
            Text(headline)
                .font(.bardDisplay(17, weight: .medium))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        switch viewModel.job.kind {
        case .epub: return "Extracting text from EPUB…"
        case .pdf: return "Extracting text from PDF…"
        case .txt: return "Loading text…"
        }
    }

    private var detail: String {
        if case .extracting(let d) = viewModel.job.state { return d }
        return ""
    }
}
