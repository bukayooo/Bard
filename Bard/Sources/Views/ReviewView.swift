import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReviewView: View {
    @Bindable var viewModel: JobViewModel
    @State private var voices: [String] = AppSettings.fallbackVoices

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Extracted Text")
                    .font(.headline)
                    .padding([.horizontal, .top])
                TextEditor(text: $viewModel.editableText)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .frame(minWidth: 380)

            VStack(alignment: .leading, spacing: 16) {
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
                .controlSize(.large)
                .disabled(viewModel.editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .frame(minWidth: 260, maxWidth: 320)
        }
        .task {
            voices = await Epub2TTSRunner.shared.listVoices()
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cover").font(.headline)
            if let coverURL = viewModel.coverPreviewURL, let image = NSImage(contentsOf: coverURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 160)
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 160)
                    .overlay(Text("No cover").foregroundStyle(.secondary))
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
            Text("Voice").font(.headline)
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
            Text("Pauses (ms)").font(.headline)
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
}
