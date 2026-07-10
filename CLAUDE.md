# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bard is a native macOS SwiftUI app that turns an EPUB, PDF, or TXT file into an audiobook (`.m4b`). It's a GUI wrapper around an external Python tool, `epub2tts-edge` (not part of this repo), which does the actual text-to-speech via Microsoft's `edge-tts`. PDFs go through a separate OCR pipeline using the Mistral API before they can be handed to `epub2tts-edge`.

## Project setup

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `Bard.xcodeproj` is checked into git, but `project.yml` is the source of truth. After editing `project.yml` (or adding/removing source files, since XcodeGen scans the `Bard/Sources` and `Bard/Resources` paths), regenerate the project:

```sh
xcodegen generate
```

Deployment target is macOS 14.0, Swift 6.0 (strict concurrency applies — see the `@unchecked Sendable` notes in `AppSettings`/`ActiveJobsRegistry` before touching cross-actor state).

## Build & run

```sh
xcodebuild -workspace Bard.xcodeproj/project.xcworkspace -scheme Bard -configuration Debug build
```

Or open `Bard.xcodeproj/project.xcworkspace` in Xcode and Cmd+R. There is currently no test target (the `Bard` scheme's `TestAction` is empty) — don't assume `xcodebuild test` does anything.

`buildServer.json` (xcode-build-server) and `.vscode/settings.json` (SweetPad) are present for editing/building from VS Code/Cursor instead of Xcode.

### External runtime dependency

The app shells out to a Python venv at a user-configured path (default `~/epub2tts-edge`, see `AppSettings.epub2ttsRepoPath`), expecting `.venv/bin/epub2tts-edge` and `.venv/bin/edge-tts` to exist there. It also expects `ffmpeg`/`ffprobe`/`espeak-ng` to be reachable — `Epub2TTSRunner.childEnvironment()` manually injects Homebrew's bin dirs into the child process's `PATH` because a GUI-launched app doesn't inherit a shell's `PATH`. None of this is buildable/testable from within this repo; if `AppSettings.isRepoConfigured()` is false, extraction/synthesis will fail with `ProcessRunError.binaryNotFound`.

The Mistral API key (for PDF OCR) is stored in Keychain via `KeychainStore`, not in `AppSettings`/`UserDefaults`.

## Architecture

Standard MVVM, `@Observable` (not Combine), one `@MainActor` view model per job.

**Job lifecycle** (`Models/JobState.swift`): `idle → extracting → readyForReview → synthesizing → done | failed`. `ContentView` owns an array of `JobViewModel`s (one per open audiobook job, shown in the sidebar, closed by default at launch — `columnVisibility = .detailOnly`); `JobDetailView` switches on `job.state` to pick which stage view to show (`ExtractionProgressView`, `ReviewView`, `SynthesisProgressView`, `DoneView`, or the failed state).

Each job gets its own working directory under `~/Library/Application Support/Bard/Jobs/<uuid>/` (`JobFileManager.createJob`), where the source file is copied and all intermediate/output files live. `ActiveJobsRegistry` is a process-wide set of in-use job directories — it exists solely so Settings' "Clean Up Old Files" (which runs in its own SwiftUI `Scene` with no access to `ContentView`'s job list) can distinguish orphaned directories from ones backing currently-open jobs.

**Job persistence & resume across launches**: a job's working directory is deleted the moment its `.m4b` is successfully exported (`JobViewModel.startSynthesis`, right before the state flips to `.done`, so a crash in between can't leave a directory that looks resumable for a book that's already finished) — so anything still under `Jobs/` is by definition incomplete. Each job writes a `.bard-job.json` sidecar (`Models/JobMetadata.swift` + `JobFileManager.saveMetadata`/`loadMetadata`) at extraction start and again on success, recording just enough (kind, original filename, title, author) to identify it later. At launch, `ContentView.restoreIncompleteJobs()` scans `Jobs/` and rebuilds a `JobViewModel` for each leftover directory via `JobViewModel.restoring(from:)`: if extraction had already produced a `.txt` on disk, the job is restored straight to `.readyForReview` (text/cover reloaded from disk) so clicking Generate again resumes synthesis — `epub2tts-edge` itself skips chapters it already rendered, which is what makes this safe. If extraction never finished, the job is restored as `.failed` with a message to delete and re-add the source, rather than silently re-running (a PDF interrupted mid-OCR could otherwise burn API calls again invisibly).

**Stage 1 — extraction** (`JobViewModel.beginExtraction`, dispatches by `SourceKind`):
- `.epub` → `Epub2TTSRunner.extract` runs `epub2tts-edge <file>` to produce a `.txt` + optional cover `.png` alongside the source.
- `.pdf` → `MistralOCRService.convertPDF`, a 3-phase pipeline (see doc comment in `Services/MistralOCRService.swift`): (1) raw deterministic OCR per page via Mistral's `/v1/ocr`, chunked via `PDFSplitter.splitIntoChunks` to bound request size; (2) one chat call over the leading pages to detect title/author and where real content starts (skip cover/TOC/copyright); (3) a *per-page* chat cleanup call that edits the real OCR text in place (strip footnotes/margins, mark headings, and — if the *entire* page is non-English or archaic-spelled English like Middle/Early Modern English — translate/modernize the whole page, leaving a page that's merely quoting/referencing another language untouched) rather than regenerating it — kept to one page per call specifically to bound hallucination risk. The first PDF page is also rendered directly as a fallback cover (no API call).
- `.txt` → read directly, no external process.

**Review stage**: user edits the extracted text in-app (or in an external editor configured in Settings — `JobViewModel` reconciles disk changes by modification-date comparison since there's no file watcher) and can swap the cover image, before starting synthesis. A "Cleanup" button (`JobViewModel.cleanUpText` → `Services/TextCleanupService.swift`) is also available here for any source kind: unlike PDFs, epub/txt extraction never involves an LLM, so this is an opt-in pass that chunks the current text (~25 paragraphs per chunk, processed concurrently) through Mistral chat to fix extraction artifacts (broken line breaks, stray markup, footnote reference markers like `word31` or `word[31]` left over from stripped superscripts) and apply the same whole-chunk-only translation/modernization rule as the PDF pipeline. It splits off and reattaches the `Title:`/`Author:` header and leaves `# ` chapter headings untouched so those never get reworded.

**Stage 2 — synthesis** (`JobViewModel.startSynthesis` → `Epub2TTSRunner.synthesize`): re-runs `epub2tts-edge` on the (possibly edited) `.txt`, this time producing the final `.m4b`. Must run with `currentDirectory` set to the txt's directory because `epub2tts-edge` writes relative temp files there. Output is copied to the user's configured output folder (`JobFileManager.exportOutput`, default `~/Documents/Audiobooks`) and a notification fires if the app isn't frontmost. While synthesis runs, `SynthesisProgressView` shows one of four looping GIFs bundled in `Resources/GIFs/` (rotated per-job via `SynthesisGIFLibrary`, decoded and rendered by `Services/GIFPlayer.swift`); the screen's background is set to that GIF's own average color (sampled from its first frame) rather than the app's usual light/dark canvas, with foreground text/controls picked by that color's actual luminance so it stays legible regardless of which GIF is showing.

**Whole-book progress tracking** is the trickiest part of this codebase and is spread across `Services/BookProgressEstimator.swift` and the bottom half of `ViewModels/JobViewModel.swift`. `epub2tts-edge` only reports *per-chapter* tqdm progress (resets to 0% each chapter) and has no concept of whole-book completion, and its final ffmpeg merge/re-encode pass has no progress indicator at all. Bard works around both: `BookProgressEstimator` mirrors `epub2tts-edge`'s own chapter/paragraph-splitting logic ahead of time so per-chapter tqdm counts can be translated into a whole-book fraction, and once TTS is done, `JobViewModel` probes the finished chapter audio files' total duration via `ffprobe` and compares it against ffmpeg's live `time=` stderr output to estimate the merge pass's progress. Read the inline comments there before changing progress math — several subtle ordering bugs (stdout/stderr interleaving, `\r`-only tqdm redraws, ffmpeg's block-buffered stdio) are documented at the point they were fixed.

**Process execution** (`Epub2TTSRunner.runProcess`): stdout and stderr are combined into a single pipe (not two) to preserve true chronological ordering between `epub2tts-edge`'s stdout chapter names and tqdm's stderr progress bars. Child processes get an empty `standardInput` pipe so they can't inherit Bard's controlling terminal and get suspended by SIGTTIN/SIGTTOU when run from an IDE's integrated terminal.

## Code style notes seen throughout

- Comments in this codebase are reserved for non-obvious *why* (a workaround, an ordering constraint, a past bug) — see nearly every file under `Services/`. Match that bar rather than describing *what* code does.
- `@Observable` + `@MainActor` for anything UI-facing; plain `actor`s (`Epub2TTSRunner`, `ProcessHandleBox`) for process/IO work off the main actor.
