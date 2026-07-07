import Foundation

enum ProcessRunError: Error, LocalizedError {
    case binaryNotFound(String)
    case nonZeroExit(Int32, String)
    case launchFailed(String)
    case outputMissing(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "epub2tts-edge not found at \(path). Set the correct repo path in Settings."
        case .nonZeroExit(let code, let tail):
            return "epub2tts-edge exited with code \(code).\n\(tail)"
        case .launchFailed(let msg):
            return "Failed to launch process: \(msg)"
        case .outputMissing(let name):
            return "Expected output file was not produced: \(name)"
        }
    }
}

/// A cancellable handle to a currently-running external process, set once the
/// process actually launches so a SwiftUI view can cancel a long-running job.
actor ProcessHandleBox {
    private var process: Process?
    fileprivate func setProcess(_ p: Process) { process = p }
    func cancel() {
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

private actor TailBuffer {
    private var lines: [String] = []
    func append(_ line: String) {
        lines.append(line)
        if lines.count > 30 { lines.removeFirst() }
    }
    func text() -> String { lines.joined(separator: "\n") }
}

private actor LineCollector {
    private var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func all() -> [String] { lines }
}

actor Epub2TTSRunner {
    static let shared = Epub2TTSRunner()

    /// Runs `epub2tts-edge <epub>` to extract the text + cover image alongside the source file.
    @discardableResult
    func extract(
        epubURL: URL,
        workDir: URL,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> (txtURL: URL, coverURL: URL?) {
        let binary = AppSettings.shared.epub2ttsBinaryURL
        try await runProcess(
            executableURL: binary, arguments: [epubURL.path], currentDirectory: workDir,
            onOutputLine: onOutputLine, handle: nil)

        let base = epubURL.deletingPathExtension()
        let txtURL = base.appendingPathExtension("txt")
        let pngURL = base.appendingPathExtension("png")
        guard FileManager.default.fileExists(atPath: txtURL.path) else {
            throw ProcessRunError.outputMissing(txtURL.lastPathComponent)
        }
        let coverURL = FileManager.default.fileExists(atPath: pngURL.path) ? pngURL : nil
        return (txtURL, coverURL)
    }

    /// Runs `epub2tts-edge <txt> --cover ... --speaker ...` to render the final audiobook.
    /// Must run with currentDirectory == the txt file's directory: epub2tts-edge writes
    /// relative temp files (filelist.txt, per-sentence audio) into the process CWD.
    @discardableResult
    func synthesize(
        txtURL: URL,
        coverURL: URL?,
        speaker: String,
        sentencePauseMs: Int,
        paragraphPauseMs: Int,
        onOutputLine: @escaping @Sendable (String) -> Void,
        handle: ProcessHandleBox?
    ) async throws -> URL {
        let binary = AppSettings.shared.epub2ttsBinaryURL
        var arguments = [
            txtURL.path,
            "--speaker", speaker,
            "--sentencepause", String(sentencePauseMs),
            "--paragraphpause", String(paragraphPauseMs),
        ]
        if let coverURL {
            arguments.append(contentsOf: ["--cover", coverURL.path])
        }
        let workDir = txtURL.deletingLastPathComponent()
        try await runProcess(
            executableURL: binary, arguments: arguments, currentDirectory: workDir,
            onOutputLine: onOutputLine, handle: handle)

        let m4bURL = txtURL.deletingPathExtension().appendingPathExtension("m4b")
        guard FileManager.default.fileExists(atPath: m4bURL.path) else {
            throw ProcessRunError.outputMissing(m4bURL.lastPathComponent)
        }
        return m4bURL
    }

    /// Best-effort voice list via `edge-tts --list-voices`; falls back to a
    /// hardcoded list of common English voices if the tool can't be run.
    func listVoices() async -> [String] {
        let binary = AppSettings.shared.edgeTTSBinaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return AppSettings.fallbackVoices
        }
        let collector = LineCollector()
        do {
            try await runProcess(
                executableURL: binary, arguments: ["--list-voices"],
                currentDirectory: FileManager.default.temporaryDirectory,
                onOutputLine: { line in await collector.append(line) }, handle: nil)
        } catch {
            return AppSettings.fallbackVoices
        }
        let lines = await collector.all()
        let voices: [String] = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("Neural") else { return nil }
            return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
        }
        let unique = Array(Set(voices)).sorted()
        return unique.isEmpty ? AppSettings.fallbackVoices : unique
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL,
        onOutputLine: @escaping @Sendable (String) async -> Void,
        handle: ProcessHandleBox?
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessRunError.binaryNotFound(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let handle {
            await handle.setProcess(process)
        }

        let tail = TailBuffer()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await line in outPipe.fileHandleForReading.bytes.lines {
                    await tail.append(line)
                    await onOutputLine(line)
                }
            }
            group.addTask {
                for try await line in errPipe.fileHandleForReading.bytes.lines {
                    await tail.append(line)
                    await onOutputLine(line)
                }
            }
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in
                        continuation.resume()
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: ProcessRunError.launchFailed(error.localizedDescription))
                    }
                }
            }
            try await group.waitForAll()
        }

        if process.terminationStatus != 0 {
            let tailText = await tail.text()
            throw ProcessRunError.nonZeroExit(process.terminationStatus, tailText)
        }
    }
}
