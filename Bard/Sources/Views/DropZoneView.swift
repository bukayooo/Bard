import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onFileChosen: (URL) -> Void
    @State private var isTargeted = false

    private static let epubType = UTType(filenameExtension: "epub") ?? .data

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.and.wrench")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Drop an EPUB, PDF, or TXT file")
                .font(.title2)
            Text("Bard will extract the text and turn it into an audiobook")
                .foregroundStyle(.secondary)
            Button("Choose File…") {
                chooseFile()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
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
