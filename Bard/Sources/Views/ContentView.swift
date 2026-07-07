import SwiftUI

struct ContentView: View {
    @State private var jobViewModels: [JobViewModel] = []
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(jobViewModels, id: \.job.id) { vm in
                    JobRow(viewModel: vm)
                        .tag(vm.job.id)
                }
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
            }
            .frame(minWidth: 220)
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
    }

    private func startJob(with url: URL) {
        guard let kind = SourceKind.from(url: url) else { return }
        do {
            let (workDir, _) = try JobFileManager.createJob(for: url)
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
}

private struct JobRow: View {
    let viewModel: JobViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(
                viewModel.job.title.isEmpty
                    ? viewModel.job.originalURL.lastPathComponent : viewModel.job.title
            )
            .font(.headline)
            .lineLimit(1)
            Text(statusText)
                .font(.caption)
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
