import SwiftUI

struct ExtractionProgressView: View {
    let viewModel: JobViewModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(headline)
                .font(.title3)
            if !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            LogView(lines: viewModel.job.log)
                .frame(maxHeight: 220)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        switch viewModel.job.kind {
        case .epub: return "Extracting text from EPUB…"
        case .pdf: return "Converting PDF with Mistral OCR…"
        case .txt: return "Loading text…"
        }
    }

    private var detail: String {
        if case .extracting(let d) = viewModel.job.state { return d }
        return ""
    }
}
