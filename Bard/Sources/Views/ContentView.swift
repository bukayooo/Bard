import SwiftUI

struct ContentView: View {
    @State private var jobViewModels: [JobViewModel] = []
    @State private var selectedID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedID) {
                ForEach(jobViewModels, id: \.job.id) { vm in
                    JobRow(viewModel: vm)
                        .tag(vm.job.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                deleteJob(vm)
                            }
                        }
                }
                .onDelete(perform: deleteJobs)
            }
            .onDeleteCommand {
                deleteSelectedJob()
            }
            .navigationTitle("Bard")
            .toolbar {
                ToolbarItem {
                    Button {
                        selectedID = nil
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .help("Start a new audiobook")
                }
                ToolbarItem {
                    Button(role: .destructive) {
                        clearFailedJobs()
                    } label: {
                        Label("Clear Failed", systemImage: "trash")
                    }
                    .help("Remove all failed jobs")
                    .disabled(!jobViewModels.contains { $0.job.state.isFailed })
                }
            }
            // Use NavigationSplitView's own column-sizing API rather than a plain
            // .frame(minWidth:) here — mixing the two caused layout conflicts
            // (visible glitches/overlap) whenever the window wasn't at a very
            // generous size, since raw frame constraints on a split-view column
            // fight the split view's own resize/collapse math.
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let vm = jobViewModels.first(where: { $0.job.id == selectedID }) {
                JobDetailView(viewModel: vm)
                    .id(vm.job.id)
            } else {
                DropZoneView { url in
                    startJob(with: url)
                }
            }
        }
        .task {
            restoreIncompleteJobs()
        }
    }

    /// Repopulates the sidebar with any job directories left over from a previous
    /// launch that never finished (Bard quit or crashed mid-extraction or
    /// mid-synthesis) — completed jobs delete their own working directory right
    /// after export, so anything found here is inherently incomplete and worth
    /// surfacing rather than silently discarding.
    private func restoreIncompleteJobs() {
        for dir in JobFileManager.orphanedJobDirs(excluding: []) {
            guard let vm = JobViewModel.restoring(from: dir) else { continue }
            ActiveJobsRegistry.shared.register(dir)
            jobViewModels.append(vm)
        }
    }

    private func startJob(with url: URL) {
        guard let kind = SourceKind.from(url: url) else { return }
        do {
            let (workDir, _) = try JobFileManager.createJob(for: url)
            ActiveJobsRegistry.shared.register(workDir)
            let job = Job(kind: kind, originalURL: url, workDir: workDir)
            let vm = JobViewModel(job: job)
            jobViewModels.append(vm)
            selectedID = job.id
            Task { await vm.beginExtraction() }
        } catch {
            let job = Job(kind: kind, originalURL: url, workDir: FileManager.default.temporaryDirectory)
            job.state = .failed(error.localizedDescription)
            let vm = JobViewModel(job: job)
            jobViewModels.append(vm)
            selectedID = job.id
        }
    }

    /// Removes a job from the list and cleans up its working directory — for
    /// failed jobs especially, that can hold tens to hundreds of MB of partial
    /// audio, so "delete" here means actually reclaiming the disk space too.
    private func deleteJob(_ vm: JobViewModel) {
        if case .synthesizing = vm.job.state {
            vm.cancelSynthesis()
        }
        if selectedID == vm.job.id {
            selectedID = nil
        }
        jobViewModels.removeAll { $0.job.id == vm.job.id }
        ActiveJobsRegistry.shared.unregister(vm.job.workDir)
        try? FileManager.default.removeItem(at: vm.job.workDir)
    }

    private func deleteJobs(at offsets: IndexSet) {
        for vm in offsets.map({ jobViewModels[$0] }) {
            deleteJob(vm)
        }
    }

    private func deleteSelectedJob() {
        guard let id = selectedID, let vm = jobViewModels.first(where: { $0.job.id == id }) else { return }
        deleteJob(vm)
    }

    private func clearFailedJobs() {
        for vm in jobViewModels.filter({ $0.job.state.isFailed }) {
            deleteJob(vm)
        }
    }
}

private struct JobRow: View {
    let viewModel: JobViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(
                viewModel.job.title.isEmpty
                    ? viewModel.job.originalURL.lastPathComponent : viewModel.job.title
            )
            .font(.system(.headline, design: .serif))
            .lineLimit(1)
            Text(statusText)
                .font(.system(.caption, design: .serif))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch viewModel.job.state {
        case .idle: return "Idle"
        case .extracting(let detail): return detail.isEmpty ? "Extracting…" : detail
        case .readyForReview: return "Ready for review"
        case .synthesizing: return "Generating audio…"
        case .done: return "Done"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}
