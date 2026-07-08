import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onFileChosen: (URL) -> Void
    @State private var isTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    private static let epubType = UTType(filenameExtension: "epub") ?? .data

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            ZStack {
                Circle()
                    .fill(BardTheme.terracotta.opacity(colorScheme == .dark ? 0.16 : 0.12))
                    .frame(width: 108, height: 108)
                Image(systemName: "theatermasks")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(BardTheme.terracotta)
            }

            VStack(spacing: 8) {
                Text("Bard")
                    .font(.bardDisplay(30))
                Text("Drop an EPUB, PDF, or TXT file to begin")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(.secondary)
            }

            GreekKeyRule()
                .frame(width: 220)
                .opacity(0.7)

            Button {
                chooseFile()
            } label: {
                Text("Choose File…")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(BardTheme.terracotta)
            .controlSize(.large)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(isTargeted ? BardTheme.terracotta.opacity(0.08) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.epubType, .pdf, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, SourceKind.from(url: url) != nil {
            onFileChosen(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                SourceKind.from(url: url) != nil
            else { return }
            DispatchQueue.main.async {
                onFileChosen(url)
            }
        }
        return true
    }
}
