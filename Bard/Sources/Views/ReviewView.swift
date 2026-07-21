import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReviewView: View {
    @Bindable var viewModel: JobViewModel
    @State private var voices: [String] = AppSettings.fallbackVoices
    @State private var isCoverDropTargeted = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: "Extracted Text")
                    Spacer()
                    if viewModel.isCleaningUpText {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.cleanupStatus ?? "Cleaning up…")
                            .font(.system(.caption, design: .serif))
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await viewModel.cleanUpText() }
                        } label: {
                            Label("Cleanup", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(BardTheme.terracotta)
                        .disabled(viewModel.editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(
                            "Use AI to fix formatting issues from extraction and translate/modernize "
                                + "text that's entirely in another language or archaic spelling "
                                + "(uses your Mistral API key)")
                    }
                    Button {
                        viewModel.reloadFromDisk()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(BardTheme.terracotta)
                    .help("Reload the text file from disk (e.g. after editing it externally)")
                    if AppSettings.shared.hasExternalEditor {
                        Button {
                            viewModel.openInExternalEditor()
                        } label: {
                            Label(
                                "Open in \(AppSettings.shared.externalEditorName)",
                                systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(BardTheme.terracotta)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
                if let cleanupError = viewModel.cleanupError {
                    Text(cleanupError)
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
                TextEditor(text: $viewModel.editableText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .disabled(viewModel.isCleaningUpText)
            }
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 18) {
                coverSection
                Divider()
                voiceSection
                Divider()
                pauseSection
                Spacer()
                Button {
                    Task { await viewModel.startSynthesis() }
                } label: {
                    Label("Generate Audiobook", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BardTheme.terracotta)
                .controlSize(.large)
                .disabled(viewModel.editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
        }
        .task {
            voices = await Epub2TTSRunner.shared.listVoices()
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Cover")
            Group {
                if let coverURL = viewModel.coverPreviewURL, let image = NSImage(contentsOf: coverURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 160)
                        .overlay(Text("No cover").foregroundStyle(.secondary))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isCoverDropTargeted ? BardTheme.terracotta : BardTheme.terracottaDeep.opacity(0.4),
                        lineWidth: isCoverDropTargeted ? 2 : 1)
            )
            .dropDestination(for: URL.self) { items, _ in
                guard let url = items.first(where: isImageFile) else { return false }
                viewModel.chooseCoverImage(url: url)
                return true
            } isTargeted: { targeted in
                isCoverDropTargeted = targeted
            }
            if viewModel.job.kind == .pdf {
                Button("Use First Page of PDF") {
                    viewModel.useFirstPDFPageAsCover()
                }
            }
            Button(viewModel.coverPreviewURL == nil ? "Choose Image…" : "Replace Image…") {
                chooseCoverImage()
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Voice")
            Picker("Speaker", selection: $viewModel.speaker) {
                ForEach(voices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }
            .labelsHidden()
        }
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Pauses (ms)")
            Stepper(
                "Sentence: \(viewModel.sentencePauseMs)", value: $viewModel.sentencePauseMs,
                in: 0...5000, step: 100)
            Stepper(
                "Paragraph: \(viewModel.paragraphPauseMs)", value: $viewModel.paragraphPauseMs,
                in: 0...5000, step: 100)
        }
    }

    private func chooseCoverImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.chooseCoverImage(url: url)
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
