import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showingCleanupConfirmation = false

    var body: some View {
        Form {
            Section("Mistral API") {
                SecureField("API Key", text: $viewModel.apiKey)
                Text("Used only to OCR PDFs into text via Mistral's OCR API.")
                    .font(.system(.caption, design: .serif))
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
                .foregroundStyle(viewModel.repoConfigured ? BardTheme.terracotta : .orange)
                .font(.system(.caption, design: .serif))
            }

            Section("Text Editor") {
                HStack {
                    TextField("External editor app", text: $viewModel.externalEditorPath)
                    Button("Choose App…") { chooseExternalEditor() }
                    if !viewModel.externalEditorPath.isEmpty {
                        Button("Clear") { viewModel.clearExternalEditor() }
                    }
                }
                Text(
                    viewModel.externalEditorPath.isEmpty
                        ? "Optional. Pick an app (e.g. BBEdit, Sublime Text) to edit extracted text there instead of the built-in editor."
                        : "The Review screen will offer to open extracted text in this app."
                )
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.secondary)
            }

            Section("Defaults") {
                Picker("Speaker", selection: $viewModel.defaultSpeaker) {
                    ForEach(viewModel.voices, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                Link("Listen to voice samples", destination: URL(string: "https://geeksta.net/tools/tts-samples/")!)
                    .font(.system(.caption, design: .serif))
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

            Section("Storage") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Old job files")
                        Text(orphanedSummary)
                            .font(.system(.caption, design: .serif))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clean Up…") {
                        viewModel.scanForOrphanedJobDirs()
                        showingCleanupConfirmation = true
                    }
                }
                Text(
                    "Removes leftover working files from jobs no longer shown in the sidebar (e.g. from previous launches or after a crash). Finished audiobooks already saved to your output folder are not affected."
                )
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .tint(BardTheme.terracotta)
        .task {
            await viewModel.refreshVoices()
            viewModel.scanForOrphanedJobDirs()
        }
        .confirmationDialog(
            "Delete \(viewModel.orphanedJobDirsCount) old job folder\(viewModel.orphanedJobDirsCount == 1 ? "" : "s")?",
            isPresented: $showingCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.deleteOrphanedJobDirs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees up \(ByteCountFormatter.string(fromByteCount: viewModel.orphanedJobsSize, countStyle: .file)).")
        }
    }

    private var orphanedSummary: String {
        viewModel.orphanedJobDirsCount == 0
            ? "None found"
            : "\(viewModel.orphanedJobDirsCount) folder\(viewModel.orphanedJobDirsCount == 1 ? "" : "s"), "
                + ByteCountFormatter.string(fromByteCount: viewModel.orphanedJobsSize, countStyle: .file)
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

    private func chooseExternalEditor() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.chooseExternalEditor(url: url)
        }
    }
}
