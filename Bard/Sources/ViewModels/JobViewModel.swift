import AppKit
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
    /// Modification date of job.txtURL as of our last write/read from Bard's side,
    /// so we can tell whether an external editor has since saved newer content.
    private var lastDiskSyncDate: Date?

    /// Set while synthesizing if no output has arrived in a while — epub2tts-edge's
    /// underlying edge-tts network calls have no timeout, so a stalled/rate-limited
    /// connection to Microsoft's TTS service hangs silently rather than erroring.
    /// This doesn't cancel anything automatically; it just makes a real stall visible
    /// instead of an indefinite, indistinguishable-from-working spinner.
    var stallWarning: String?
    private var lastOutputAt = Date()
    private var watchdogTask: Task<Void, Never>?

    // MARK: - Whole-book progress tracking
    // epub2tts-edge's own progress output (tqdm) is per-chapter only, resetting to 0%
    // at the start of every chapter. To show *book-wide* progress instead, we mirror
    // its own chapter/paragraph split (BookProgressEstimator) ahead of time, then
    // track which chapter is active and how far into it we are as output streams in.
    private var chapterParagraphCounts: [Int] = []
    private var totalParagraphs = 0
    private var chapterCursor = -1
    private var completedParagraphsBeforeCurrent = 0
    private var currentChapterCompleted = 0
    private var ttsComplete = false
    // The final ffmpeg merge/re-encode (two passes) has no progress bar of its own,
    // just a live `time=` counter with no stated total — probed via ffprobe against
    // the now-finished chapter audio files and folded into the last slice of the bar.
    private var mergeTargetDuration: Double?
    private var mergePassIndex = 1
    private var mergeCurrentPassSeconds = 0.0
    private let mergeReserveFraction = 0.08
    // ffmpeg switches to block-buffered stdio once stderr isn't a tty, so its own
    // progress ticks and "muxing overhead" summary can arrive out of true
    // chronological order at the pipe level (verified against a real run — a
    // pass's final tick occasionally surfaces just after that pass's own summary
    // line). Rather than chase that fully, clamp the displayed value so it never
    // visibly moves backward; it still converges correctly moments later.
    private var maxObservedFraction = 0.0

    private static let tqdmCountRegex = /(\d+)\/(\d+)\s*\[/
    private static let ffmpegTimeRegex = /time=(\d+):(\d+):(\d+(?:\.\d+)?)/

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
        lastDiskSyncDate = modificationDate(of: result.txtURL)
    }

    private func extractPDF() async throws {
        let sourceURL = sourceInWorkDir

        // Default cover: first page of the PDF, rendered immediately (no API call needed).
        useFirstPDFPageAsCover()

        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            throw MistralOCRError.missingAPIKey
        }
        let service = try MistralOCRService(apiKey: apiKey)
        let bookText = try await service.convertPDF(url: sourceURL) { [weak self] phase, completed, total in
            Task { @MainActor in
                self?.job.state = .extracting(detail: "\(phase) \(completed)/\(total)")
                self?.job.appendLog("\(phase) \(completed)/\(total) done")
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
        lastDiskSyncDate = modificationDate(of: txtURL)
    }

    private func extractPlainText() throws {
        let sourceURL = sourceInWorkDir
        editableText = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        job.txtURL = sourceURL
        applyTitleAuthorFromText()
        lastDiskSyncDate = modificationDate(of: sourceURL)
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

    // MARK: - External editor

    /// Saves the current text to disk and opens it in the user's configured external
    /// editor (Settings > Text Editor). Since editing then happens outside Bard,
    /// `startSynthesis()` checks the file's modification date and reloads from disk
    /// if the external editor saved something newer before we'd overwrite it.
    func openInExternalEditor() {
        guard let txtURL = job.txtURL, let editorURL = AppSettings.shared.externalEditorURL else { return }
        do {
            try editableText.write(to: txtURL, atomically: true, encoding: .utf8)
            lastDiskSyncDate = modificationDate(of: txtURL)
        } catch {
            job.appendLog("Could not save text before opening external editor: \(error.localizedDescription)")
            return
        }
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.open(
                    [txtURL], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                self.job.appendLog("Could not launch external editor: \(error.localizedDescription)")
            }
        }
    }

    /// Explicit "Refresh" action for the Review screen: reloads the text from disk,
    /// discarding whatever's in the in-app editor. Needed because edits made in an
    /// external editor otherwise only get picked up right before synthesis starts —
    /// there's no live file-watching while you're just sitting on the Review screen.
    func reloadFromDisk() {
        guard let txtURL = job.txtURL, let text = try? String(contentsOf: txtURL, encoding: .utf8) else {
            return
        }
        editableText = text
        lastDiskSyncDate = modificationDate(of: txtURL)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// If the file on disk is newer than what Bard last wrote/read, an external editor
    /// saved changes since — pull those into the in-app text instead of clobbering them.
    private func reconcileExternalEdits(txtURL: URL) {
        guard let onDisk = modificationDate(of: txtURL), let known = lastDiskSyncDate, onDisk > known else {
            return
        }
        if let text = try? String(contentsOf: txtURL, encoding: .utf8) {
            editableText = text
        }
    }

    // MARK: - Stage 2: synthesis

    func startSynthesis() async {
        guard let txtURL = job.txtURL else { return }
        userCancelled = false
        reconcileExternalEdits(txtURL: txtURL)
        do {
            try editableText.write(to: txtURL, atomically: true, encoding: .utf8)
            lastDiskSyncDate = modificationDate(of: txtURL)
        } catch {
            job.state = .failed("Could not save edited text: \(error.localizedDescription)")
            return
        }

        job.state = .synthesizing(detail: "Starting…", fraction: nil)
        let handle = ProcessHandleBox()
        processHandle = handle
        stallWarning = nil
        lastOutputAt = Date()
        startWatchdog()

        chapterParagraphCounts = BookProgressEstimator.chapterParagraphCounts(bookText: editableText)
        totalParagraphs = chapterParagraphCounts.reduce(0, +)
        chapterCursor = -1
        completedParagraphsBeforeCurrent = 0
        currentChapterCompleted = 0
        ttsComplete = false
        maxObservedFraction = 0
        mergeTargetDuration = nil
        mergePassIndex = 1
        mergeCurrentPassSeconds = 0

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
                        self.lastOutputAt = Date()
                        self.stallWarning = nil
                        self.updateOverallProgress(for: line)
                        self.job.state = .synthesizing(detail: line, fraction: self.computeOverallFraction())
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
            if !NSApp.isActive {
                NotificationService.notifyAudiobookReady(title: exportTitle)
            }
        } catch {
            if userCancelled {
                job.state = .failed("Cancelled.")
            } else {
                job.appendLog("Error: \(error.localizedDescription)")
                job.state = .failed(error.localizedDescription)
            }
        }
        processHandle = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        stallWarning = nil
    }

    func cancelSynthesis() {
        userCancelled = true
        let handle = processHandle
        Task { await handle?.cancel() }
    }

    /// Polls every 15s while synthesizing; if nothing has printed in 45s, surfaces a
    /// warning banner. epub2tts-edge / edge-tts have no network timeout of their own,
    /// so a stalled TTS request otherwise looks identical to normal (slow) progress.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(self.lastOutputAt)
                self.stallWarning =
                    elapsed > 45
                    ? "No output for \(Int(elapsed))s — the TTS service may be slow or rate-limited right now. Still working; you can Cancel and try again if it doesn't recover."
                    : nil
            }
        }
    }

    /// Advances to the next chapter in `chapterParagraphCounts`, crediting the
    /// previous one (if any) with its full paragraph count — called whenever
    /// epub2tts-edge prints either "Chapter name: ..." (about to process a chapter)
    /// or "...exists, skipping to next chapter" (chapter already done from a prior
    /// interrupted run); both mean one whole chapter is now accounted for.
    private func advanceChapter() {
        if chapterCursor >= 0, chapterCursor < chapterParagraphCounts.count {
            completedParagraphsBeforeCurrent += chapterParagraphCounts[chapterCursor]
        }
        chapterCursor += 1
        currentChapterCompleted = 0
    }

    private func updateOverallProgress(for line: String) {
        guard totalParagraphs > 0 else { return }

        if line.hasPrefix("Chapter name: \"") || line.hasSuffix("exists, skipping to next chapter") {
            advanceChapter()
        } else if let match = try? Self.tqdmCountRegex.firstMatch(in: line), let current = Int(match.1) {
            currentChapterCompleted = current
        }

        // ffmpeg prints one "muxing overhead:" summary line per pass, strictly once
        // that pass has fully finished writing output — unlike a bare "[out#0/mp4"
        // prefix, which also shows up on assorted in-progress diagnostic lines and
        // so falsely signals "pass 2 started" while pass 1 is still mid-encode
        // (verified against a real run: caused the bar to jump ahead then regress).
        if line.contains("muxing overhead:") {
            if !ttsComplete {
                ttsComplete = true
                beginProbingMergeDuration()
            }
            if mergePassIndex == 1 {
                mergePassIndex = 2
                mergeCurrentPassSeconds = 0
            }
        } else if let match = try? Self.ffmpegTimeRegex.firstMatch(in: line),
            let hours = Double(match.1), let minutes = Double(match.2), let seconds = Double(match.3)
        {
            // The first ffmpeg time= line is our signal that TTS is fully done and
            // merging has begun — not the paragraph count reaching its total, which
            // fires while the last chapter's own audio file is still being written
            // (read_book() exports it to disk *after* its tqdm loop reaches 100%,
            // before ffmpeg ever runs) and would race the duration probe below.
            if !ttsComplete {
                ttsComplete = true
                beginProbingMergeDuration()
            }
            mergeCurrentPassSeconds = hours * 3600 + minutes * 60 + seconds
        }
    }

    /// Probes the now-finished chapter audio files' total duration in the background,
    /// so it's ready (or close to it) by the time ffmpeg's own `time=` lines start
    /// arriving moments later — ffmpeg only starts once every part file is written.
    private func beginProbingMergeDuration() {
        let dir = job.workDir
        Task.detached { [weak self] in
            let duration = await Epub2TTSRunner.probeTotalPartDuration(in: dir)
            await MainActor.run {
                self?.mergeTargetDuration = duration
            }
        }
    }

    private func computeOverallFraction() -> Double? {
        guard totalParagraphs > 0 else { return nil }
        let synthesisFraction = min(
            max(Double(completedParagraphsBeforeCurrent + currentChapterCompleted) / Double(totalParagraphs), 0), 1)

        let raw: Double
        if !ttsComplete {
            raw = synthesisFraction * (1 - mergeReserveFraction)
        } else {
            var mergeFraction = 0.0
            if let target = mergeTargetDuration, target > 0 {
                let base = mergePassIndex == 1 ? 0.0 : target
                mergeFraction = min(max((base + mergeCurrentPassSeconds) / (2 * target), 0), 1)
            }
            raw = (1 - mergeReserveFraction) + mergeReserveFraction * mergeFraction
        }

        maxObservedFraction = max(maxObservedFraction, raw)
        return maxObservedFraction
    }
}
