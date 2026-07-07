import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Mistral API") {
                SecureField("API Key", text: $viewModel.apiKey)
                Text("Used only to OCR PDFs into text via Mistral's OCR API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("epub2tts-edge") {
                HStack {
                    TextField("Repo path", text: $viewModel.repoPath)
                    Button("Locate…") { chooseRepo() }
                }
                Label(
                    viewModel.repoConfigured
                        ? "Found epub2tts-edge" : "epub2tts-edge binary not found at this path",
                    systemImage: viewModel.repoConfigured ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(viewModel.repoConfigured ? .green : .orange)
                .font(.caption)
            }

            Section("Defaults") {
                Picker("Speaker", selection: $viewModel.defaultSpeaker) {
                    ForEach(viewModel.voices, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                Stepper(
                    "Sentence pause: \(viewModel.sentencePauseMs) ms",
                    value: $viewModel.sentencePauseMs, in: 0...5000, step: 100)
                Stepper(
                    "Paragraph pause: \(viewModel.paragraphPauseMs) ms",
                    value: $viewModel.paragraphPauseMs, in: 0...5000, step: 100)
            }

            Section("Output") {
                HStack {
                    TextField("Output folder", text: $viewModel.outputFolderPath)
                    Button("Choose…") { chooseOutputFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task {
            await viewModel.refreshVoices()
        }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.chooseRepoFolder(url: url)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.chooseOutputFolder(url: url)
        }
    }
}
