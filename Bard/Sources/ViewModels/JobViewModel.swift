import Foundation

@MainActor
@Observable
final class JobViewModel {
    let job: Job

    var editableText: String = ""
    var coverPreviewURL: URL?
    var speaker: String
    var sentencePauseMs: Int
    var paragraphPauseMs: Int

    private var processHandle: ProcessHandleBox?
    private var userCancelled = false

    init(job: Job) {
        self.job = job
        self.speaker = AppSettings.shared.speaker
        self.sentencePauseMs = AppSettings.shared.sentencePauseMs
        self.paragraphPauseMs = AppSettings.shared.paragraphPauseMs
    }

    // MARK: - Stage 1: extraction / OCR

    func beginExtraction() async {
        job.state = .extracting(detail: "Starting…")
        do {
            switch job.kind {
            case .epub:
                try await extractEpub()
            case .pdf:
                try await extractPDF()
            case .txt:
                try extractPlainText()
            }
            job.state = .readyForReview
        } catch {
            job.appendLog("Error: \(error.localizedDescription)")
            job.state = .failed(error.localizedDescription)
        }
    }

    private var sourceInWorkDir: URL {
        job.workDir.appendingPathComponent(job.originalURL.lastPathComponent)
    }

    private func extractEpub() async throws {
        let sourceURL = sourceInWorkDir
        let result = try await Epub2TTSRunner.shared.extract(epubURL: sourceURL, workDir: job.workDir) {
            [weak self] line in
            Task { @MainActor in
                self?.job.appendLog(line)
                self?.job.state = .extracting(detail: line)
            }
        }
        job.txtURL = result.txtURL
        job.coverURL = result.coverURL
        coverPreviewURL = result.coverURL
        editableText = (try? String(contentsOf: result.txtURL, encoding: .utf8)) ?? ""
        applyTitleAuthorFromText()
    }

    private func extractPDF() async throws {
        let sourceURL = sourceInWorkDir

        // Default cover: first page of the PDF, rendered immediately (no API call needed).
        useFirstPDFPageAsCover()

        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            throw MistralOCRError.missingAPIKey
        }
        let service = try MistralOCRService(apiKey: apiKey)
        let bookText = try await service.convertPDF(url: sourceURL) { [weak self] completed, total in
            Task { @MainActor in
                self?.job.state = .extracting(detail: "OCR chunk \(completed)/\(total)")
                self?.job.appendLog("OCR chunk \(completed)/\(total) done")
            }
        }

        let title = bookText.title.isEmpty ? job.title : bookText.title
        let author = bookText.author
        job.title = title
        job.author = author
        editableText = "Title: \(title)\nAuthor: \(author)\n\n\(bookText.content)"

        let txtURL = job.workDir.appendingPathComponent("book.txt")
        try editableText.write(to: txtURL, atomically: true, encoding: .utf8)
        job.txtURL = txtURL
    }

    private func extractPlainText() throws {
        let sourceURL = sourceInWorkDir
        editableText = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        job.txtURL = sourceURL
        applyTitleAuthorFromText()
    }

    private func applyTitleAuthorFromText() {
        let lines = editableText.components(separatedBy: "\n")
        if lines.count >= 1, lines[0].hasPrefix("Title:") {
            job.title = lines[0].dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
        }
        if lines.count >= 2, lines[1].hasPrefix("Author:") {
            job.author = lines[1].dropFirst("Author:".count).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Cover selection (Review stage)

    func useFirstPDFPageAsCover() {
        guard job.kind == .pdf else { return }
        guard let pngData = try? PDFSplitter.renderFirstPageImage(url: sourceInWorkDir) else { return }
        let coverURL = job.workDir.appendingPathComponent("cover.png")
        try? pngData.write(to: coverURL)
        job.coverURL = coverURL
        coverPreviewURL = coverURL
    }

    func chooseCoverImage(url: URL) {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let dest = job.workDir.appendingPathComponent("cover.\(ext)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            job.coverURL = dest
            coverPreviewURL = dest
        } catch {
            job.appendLog("Could not use image: \(error.localizedDescription)")
        }
    }

    // MARK: - Stage 2: synthesis

    func startSynthesis() async {
        guard let txtURL = job.txtURL else { return }
        userCancelled = false
        do {
            try editableText.write(to: txtURL, atomically: true, encoding: .utf8)
        } catch {
            job.state = .failed("Could not save edited text: \(error.localizedDescription)")
            return
        }

        job.state = .synthesizing(detail: "Starting…", fraction: nil)
        let handle = ProcessHandleBox()
        processHandle = handle

        do {
            let m4bURL = try await Epub2TTSRunner.shared.synthesize(
                txtURL: txtURL,
                coverURL: job.coverURL,
                speaker: speaker,
                sentencePauseMs: sentencePauseMs,
                paragraphPauseMs: paragraphPauseMs,
                onOutputLine: { [weak self] line in
                    Task { @MainActor in
                        guard let self else { return }
                        self.job.appendLog(line)
                        let fraction = Self.parseProgressFraction(from: line)
                        self.job.state = .synthesizing(detail: line, fraction: fraction)
                    }
                },
                handle: handle
            )
            let exportTitle =
                job.title.isEmpty
                ? job.originalURL.deletingPathExtension().lastPathComponent : job.title
            let exported = try JobFileManager.exportOutput(
                m4bURL, title: exportTitle, to: AppSettings.shared.outputFolderURL)
            job.outputURL = exported
            job.state = .done
        } catch {
            if userCancelled {
                job.state = .failed("Cancelled.")
            } else {
                job.appendLog("Error: \(error.localizedDescription)")
                job.state = .failed(error.localizedDescription)
            }
        }
        processHandle = nil
    }

    func cancelSynthesis() {
        userCancelled = true
        let handle = processHandle
        Task { await handle?.cancel() }
    }

    private static func parseProgressFraction(from line: String) -> Double? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let match = line[range].dropLast()  // drop trailing %
        guard let value = Double(match) else { return nil }
        return min(max(value / 100.0, 0), 1)
    }
}
