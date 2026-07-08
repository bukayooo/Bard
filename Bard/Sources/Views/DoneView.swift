import AppKit
import SwiftUI

struct DoneView: View {
    let viewModel: JobViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(BardTheme.terracotta.opacity(0.14))
                    .frame(width: 92, height: 92)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(BardTheme.terracotta)
            }
            Text("Audiobook Ready")
                .font(.bardDisplay(24))
            GreekKeyRule()
                .frame(width: 160)
                .opacity(0.7)
            if let url = viewModel.job.outputURL {
                Text(url.path)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Play") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BardTheme.terracotta)
                }
            }
            Spacer()
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
