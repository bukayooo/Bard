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

    /// epub2tts-edge shells out to ffmpeg/ffprobe/espeak-ng by bare name (via pydub and
    /// espeak-ng's own lookup). Those live in Homebrew's bin dir, but a GUI-launched app
    /// (Finder/Xcode, not a Terminal shell) doesn't inherit a shell's PATH — its default
    /// PATH is just /usr/bin:/bin:/usr/sbin:/sbin — so those tools silently fail to
    /// resolve unless we add Homebrew's directories ourselves.
    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var combined: [String] = []
        for path in extraPaths + existing where !combined.contains(path) {
            combined.append(path)
        }
        env["PATH"] = combined.joined(separator: ":")
        return env
    }

    /// Probes an audio file's duration in seconds via ffprobe (used to estimate
    /// progress through epub2tts-edge's final ffmpeg merge step, which has no
    /// progress bar of its own — only a live `time=` counter with no known total).
    static func probeDurationSeconds(of url: URL) async -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ]
        process.environment = childEnvironment()
        process.standardInput = Pipe()
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            process.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.flatMap(Double.init))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Sums the duration of every `partN.flac` chapter file in a job's working
    /// directory — the target duration the final ffmpeg merge/re-encode passes
    /// will each need to reach.
    static func probeTotalPartDuration(in dir: URL) async -> Double? {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        let partFiles = files.filter {
            $0.lastPathComponent.hasPrefix("part") && $0.pathExtension == "flac"
        }
        guard !partFiles.isEmpty else { return nil }
        var total = 0.0
        for file in partFiles {
            if let seconds = await probeDurationSeconds(of: file) {
                total += seconds
            }
        }
        return total > 0 ? total : nil
    }

    /// tqdm (epub2tts-edge's per-paragraph progress bar) redraws using a bare `\r`
    /// with no trailing `\n` for every tick, only emitting a real `\n` once a chapter
    /// finishes. `FileHandle.bytes.lines` doesn't treat a lone `\r` as a line terminator,
    /// so every intermediate progress percentage was getting buffered away silently
    /// instead of reaching the UI — this reads raw bytes and manually splits on either
    /// `\r` or `\n`, matching how a real terminal would redraw the line.
    private static func streamLines(
        from pipe: Pipe,
        tail: TailBuffer,
        onOutputLine: @escaping @Sendable (String) async -> Void
    ) async throws {
        var buffer: [UInt8] = []
        for try await byte in pipe.fileHandleForReading.bytes {
            if byte == 0x0A || byte == 0x0D {
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll(keepingCapacity: true)
                    await tail.append(line)
                    await onOutputLine(line)
                }
            } else {
                buffer.append(byte)
            }
        }
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            await tail.append(line)
            await onOutputLine(line)
        }
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
        process.environment = Self.childEnvironment()

        // stdout and stderr share ONE pipe (not two) so the OS serializes writes from
        // both in true chronological order. epub2tts-edge prints chapter names to
        // stdout but tqdm's progress bars to stderr; reading those as two independent
        // streams gave no ordering guarantee between them, so e.g. a new chapter's
        // name could be observed before the previous chapter's final 100% tick —
        // which broke whole-book progress tracking (a visible backward jump).
        let combinedPipe = Pipe()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe
        // Without this, the child inherits Bard's own stdin. When Bard is launched
        // attached to a controlling terminal (e.g. an IDE's integrated terminal, as
        // with SweetPad/Cursor), a background child touching that terminal gets
        // SIGTTIN/SIGTTOU from the kernel, which *stops* the process outright —
        // no error, no crash, it just silently sits there (ps shows state "T").
        // An unconnected pipe has no controlling terminal, so this can't happen.
        process.standardInput = Pipe()

        if let handle {
            await handle.setProcess(process)
        }

        let tail = TailBuffer()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Self.streamLines(from: combinedPipe, tail: tail, onOutputLine: onOutputLine)
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
