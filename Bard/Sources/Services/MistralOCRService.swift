import Foundation
import os

enum MistralOCRError: Error, LocalizedError {
    case missingAPIKey
    case httpError(Int, String)
    case emptyResponse
    case decodeFailed(String)
    case network(String)
    /// Distinct from `.httpError` for the specific case of exhausting every
    /// rate-limit retry (see `maxRateLimitRetries`) without Mistral ever
    /// sending a `Retry-After` header. A transient traffic-driven 429 almost
    /// always includes one; several minutes of unbroken 429s with none is a
    /// much stronger signal of an account-level block (e.g. an unverified
    /// free-tier key that hasn't been granted completions access) than of a
    /// busy API, so this gets its own message pointing at the account
    /// instead of implying "just try again."
    case persistentRateLimit(attempts: Int, elapsed: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Mistral API key set. Add one in Settings."
        case .httpError(let code, let body): return "Mistral request failed (\(code)): \(body)"
        case .emptyResponse: return "Mistral returned an empty response."
        case .decodeFailed(let msg): return "Could not parse Mistral response: \(msg)"
        case .network(let msg):
            return "Lost connection to Mistral: \(msg) Pages finished so far are saved — "
                + "click Retry once you're back online to pick up where it left off."
        case .persistentRateLimit(let attempts, let elapsed):
            let minutes = Int(elapsed / 60)
            return "Mistral rate-limited every request for \(minutes) minute\(minutes == 1 ? "" : "s") straight "
                + "across \(attempts) attempts, with no Retry-After guidance from the server. That usually means "
                + "your Mistral account doesn't have completions access yet (e.g. an unverified free-tier key), "
                + "not a brief traffic spike — check console.mistral.ai under Limits and Subscription."
        }
    }
}

private struct OCRPage: Decodable {
    let markdown: String
    let header: String?
    let footer: String?
}

private struct OCRResponse: Decodable {
    let pages: [OCRPage]
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

/// Every finished OCR chunk, the front-matter result, and every cleaned page are
/// written here as they complete, so a failure partway through a long book (most
/// often a dropped connection) can be retried without re-paying for — or
/// re-waiting on — the hundreds of calls that already succeeded.
struct OCRProgressCache: Sendable {
    let dir: URL

    func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

private struct FrontMatter: Codable {
    let title: String
    let author: String
    let startIndex: Int
}

/// Client for Mistral's OCR + chat endpoints, used together to avoid the
/// hallucination that comes from asking a single LLM call to both OCR a
/// whole book *and* regenerate its content into a JSON field.
///
/// Pipeline:
///  1. Raw OCR (`/v1/ocr`, no annotation format) — deterministic, per-page
///     markdown text straight from the OCR model. This is the ground truth
///     for `content` and is never rewritten by an LLM.
///  2. One small chat call over the first few pages to pull out title/author
///     and find the heading where the main content starts (skipping cover,
///     copyright, TOC, etc).
///  3. A cleanup chat call *per page* that edits the real OCR text in place
///     (strip footnotes/margins, mark chapter headings) rather than
///     generating it from scratch. Keeping chunks to a single page bounds
///     how much the model can drift per call. The one deliberate exception to
///     "edit in place" is translation: a page that is entirely non-English or
///     entirely archaic-spelled English (Middle/Early Modern English, which
///     the TTS voice mispronounces) gets translated/modernized wholesale,
///     since per-page granularity is exactly what lets the model tell "whole
///     page in another language/era" apart from "a quotation embedded in an
///     English page" and leave the latter untouched.
struct MistralOCRService: Sendable {
    static let ocrEndpoint = URL(string: "https://api.mistral.ai/v1/ocr")!
    static let chatEndpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!

    /// Raw OCR is deterministic text extraction, not LLM generation, so this
    /// only bounds request/response size and timeouts — it has no bearing on
    /// accuracy the way chunk size does for the cleanup pass below.
    static let maxOCRPagesPerChunk = 20
    static let maxConcurrentOCRChunks = 3

    /// Kept at one page per call so the cleanup model only ever has to edit
    /// a small, boundable amount of real OCR text instead of long-range
    /// verbatim reproduction, which is what drove the hallucinations.
    static let cleanupPagesPerChunk = 1
    static let maxConcurrentCleanupChunks = 3
    static let cleanupModel = "mistral-medium-latest"

    /// How many leading pages to hand to the metadata/front-matter call.
    static let frontMatterPageBudget = 15

    static let cleanupPrompt = """
        You are cleaning up raw OCR text from a single page of a book. The running headers \
        and footers have already been stripped out programmatically - you do not need to \
        look for those. Your jobs are: (1) remove footnotes, footnote reference markers \
        (e.g. superscript numbers like [1]), and margin line/page numbers; (2) if this page \
        begins a new chapter, put "# " before that chapter title line; (3) if this page's \
        body text is written ENTIRELY in a non-English language, or entirely in archaic \
        English spelling/vocabulary that a modern text-to-speech voice would mispronounce \
        (e.g. Middle or Early Modern English like "vnderstand" for "understand", "historie" \
        for "history", "sayth" for "says"), translate/modernize the WHOLE page into fluent \
        modern English, keeping the original meaning, sentence order, and paragraph breaks \
        as close as possible. Otherwise - meaning any page that is normal modern English, or \
        modern English with only a portion (a quotation, an epigraph, a foreign phrase) in \
        another language or archaic spelling - leave every word exactly as it appears \
        (including that non-English/archaic portion): the author is likely quoting or \
        referencing something deliberately, and only a page that is uniformly foreign or \
        archaic should be translated.

        Critical rules:
        - Outside of the whole-page translation/modernization case in (3) above, never \
        invent, complete, paraphrase, reword, or summarize any text. Every word you output \
        must come directly from the input.
        - Never omit a sentence, clause, or line of body text.
        - This page is a fragment of a much longer book, so it will often start or end \
        mid-sentence. That is expected - keep the partial sentence exactly as it appears \
        (translated if rule 3 applies), don't drop it and don't try to complete it.
        - If you're unsure whether a piece of text is a footnote/margin number or actual \
        body content, keep it. Deleting real content is a worse mistake than leaving in a \
        stray number.
        - If you're unsure whether a page qualifies for whole-page translation under rule \
        (3), don't translate it - leave it exactly as-is. Only translate when the entire \
        page is clearly non-English or clearly archaic-spelled English.
        - If the page truly has no body text at all (e.g. blank or purely decorative), reply \
        with an empty string.

        Reply with only the cleaned (and, if applicable, translated) text and nothing else - \
        no preamble, no explanation, no code fences.
        """

    static let frontMatterPrompt = """
        Below is raw OCR text from the first pages of a book. It may include a cover, title \
        page, copyright page, dedication, and table of contents. Reply with EXACTLY three \
        lines and nothing else:
        Title: <the book's exact title, or blank if not found>
        Author: <the book's exact author, or blank if not found>
        Start: <verbatim text of the heading where the main content begins - the first \
        chapter/section heading that appears AFTER any table of contents - or NONE if you \
        cannot find a table of contents or a clear starting heading>
        """

    private let apiKey: String

    struct BookText {
        var title: String
        var author: String
        var content: String
    }

    init(apiKey: String) throws {
        guard !apiKey.isEmpty else { throw MistralOCRError.missingAPIKey }
        self.apiKey = apiKey
    }

    /// Runs the raw-OCR -> front-matter -> cleanup pipeline described above.
    /// `onProgress` reports (phase, completed, total) so callers can show a
    /// meaningful status across the two distinct phases.
    func convertPDF(
        url: URL,
        cache: OCRProgressCache? = nil,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> BookText {
        let pdfChunks = try PDFSplitter.splitIntoChunks(url: url, maxPages: Self.maxOCRPagesPerChunk)
        let pages = try await runOCR(pdfChunks: pdfChunks, cache: cache, onProgress: onProgress)
        guard !pages.isEmpty else { return BookText(title: "", author: "", content: "") }

        let frontMatter: FrontMatter
        if let cached = cache?.load("frontmatter.json", as: FrontMatter.self), cached.startIndex < pages.count {
            frontMatter = cached
        } else {
            let (title, author, startIndex) = try await detectFrontMatter(pages: pages)
            frontMatter = FrontMatter(title: title, author: author, startIndex: startIndex)
            cache?.save(frontMatter, as: "frontmatter.json")
        }
        let (title, author, startIndex) = (frontMatter.title, frontMatter.author, frontMatter.startIndex)

        let contentPages = Array(pages[startIndex...])
        let cleaned = try await cleanUp(
            pages: contentPages, firstPageIndex: startIndex, cache: cache, onProgress: onProgress)

        return BookText(title: title, author: author, content: cleaned.joined(separator: "\n\n"))
    }

    // MARK: - Phase 1: raw OCR

    /// Chunk size is part of the key so a cache written under a different
    /// maxOCRPagesPerChunk can't be stitched in at the wrong page offsets.
    private static func ocrCacheKey(_ chunk: Int) -> String { "ocr-\(maxOCRPagesPerChunk)-\(chunk).json" }
    private static func cleanupCacheKey(_ page: Int) -> String { "cleanup-\(page).json" }

    private func runOCR(
        pdfChunks: [Data],
        cache: OCRProgressCache?,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> [String] {
        let total = pdfChunks.count
        var results = (0..<total).map { cache?.load(Self.ocrCacheKey($0), as: [String].self) }
        var completed = results.filter { $0 != nil }.count
        if completed > 0 { onProgress("OCR", completed, total) }
        let pending = (0..<total).filter { results[$0] == nil }

        var index = 0
        while index < pending.count {
            let batchEnd = min(index + Self.maxConcurrentOCRChunks, pending.count)
            try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
                for i in pending[index..<batchEnd] {
                    let data = pdfChunks[i]
                    group.addTask {
                        let pages = try await ocrChunk(pdfData: data)
                        cache?.save(pages, as: Self.ocrCacheKey(i))
                        return (i, pages)
                    }
                }
                for try await (i, pages) in group {
                    results[i] = pages
                    completed += 1
                    onProgress("OCR", completed, total)
                }
            }
            index = batchEnd
        }

        return results.compactMap { $0 }.flatMap { $0 }
    }

    private func ocrChunk(pdfData: Data, attempt: Int = 0) async throws -> [String] {
        let base64 = pdfData.base64EncodedString()
        let body: [String: Any] = [
            "model": "mistral-ocr-latest",
            "document": [
                "type": "document_url",
                "document_url": "data:application/pdf;base64,\(base64)",
            ],
            "include_image_base64": false,
            "extract_header": true,
            "extract_footer": true,
        ]
        let data = try await post(to: Self.ocrEndpoint, body: body, attempt: attempt)
        let decoded: OCRResponse
        do {
            decoded = try JSONDecoder().decode(OCRResponse.self, from: data)
        } catch {
            throw MistralOCRError.decodeFailed(error.localizedDescription)
        }
        return decoded.pages.map { page in
            var text = page.markdown
            // extract_header/extract_footer above already separates these out;
            // strip them deterministically here rather than leaving it to the
            // cleanup LLM to spot them inside the page text.
            if let header = page.header, !header.isEmpty {
                text = text.replacingOccurrences(of: header, with: "")
            }
            if let footer = page.footer, !footer.isEmpty {
                text = text.replacingOccurrences(of: footer, with: "")
            }
            // The OCR model emits recognized figures/photos as markdown image
            // refs (e.g. "![img-0.jpeg](img-0.jpeg)"). Strip those here too -
            // no need for the cleanup LLM to recognize and drop them.
            return Self.stripImageMarkdown(text)
        }
    }

    private static let imageMarkdownRegex = try! NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)")

    private static func stripImageMarkdown(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return imageMarkdownRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Phase 2: title/author + front-matter boundary

    private func detectFrontMatter(pages: [String]) async throws -> (title: String, author: String, startIndex: Int) {
        let budget = min(Self.frontMatterPageBudget, pages.count)
        let sample = pages[0..<budget].joined(separator: "\n\n")
        let reply = try await chat(prompt: Self.frontMatterPrompt, userContent: sample)

        var title = ""
        var author = ""
        var startHeading: String?
        for line in reply.components(separatedBy: "\n") {
            if line.hasPrefix("Title:") {
                title = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Author:") {
                author = line.dropFirst("Author:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Start:") {
                let value = line.dropFirst("Start:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value != "NONE" {
                    startHeading = value
                }
            }
        }

        guard let heading = startHeading else { return (title, author, 0) }
        for (i, page) in pages.enumerated() where page.contains(heading) {
            return (title, author, i)
        }
        return (title, author, 0)
    }

    // MARK: - Phase 3: per-page cleanup

    private func cleanUp(
        pages: [String],
        firstPageIndex: Int,
        cache: OCRProgressCache?,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> [String] {
        let total = pages.count
        guard total > 0 else { return [] }
        var results = (0..<total).map { cache?.load(Self.cleanupCacheKey(firstPageIndex + $0), as: String.self) }
        var completed = results.filter { $0 != nil }.count
        if completed > 0 { onProgress("Cleanup", completed, total) }
        let pending = (0..<total).filter { results[$0] == nil }

        var index = 0
        while index < pending.count {
            let batchEnd = min(index + Self.maxConcurrentCleanupChunks, pending.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in pending[index..<batchEnd] {
                    let page = pages[i]
                    group.addTask {
                        let cleaned = try await chat(prompt: Self.cleanupPrompt, userContent: page)
                        cache?.save(cleaned, as: Self.cleanupCacheKey(firstPageIndex + i))
                        return (i, cleaned)
                    }
                }
                for try await (i, cleaned) in group {
                    results[i] = cleaned
                    completed += 1
                    onProgress("Cleanup", completed, total)
                }
            }
            index = batchEnd
        }

        return results.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Chat helper

    private func chat(prompt: String, userContent: String, attempt: Int = 0) async throws -> String {
        let body: [String: Any] = [
            "model": Self.cleanupModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": userContent],
            ],
        ]
        let data = try await post(to: Self.chatEndpoint, body: body, attempt: attempt)
        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw MistralOCRError.decodeFailed(error.localizedDescription)
        }
        guard let content = decoded.choices.first?.message.content else {
            throw MistralOCRError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP + retry

    /// 429s need much more patience than transient network/5xx errors: with a
    /// page-per-request cleanup pass, a longer book can throw dozens of
    /// concurrent requests at the API, so a single 2s retry isn't enough to
    /// ride out a rate-limit window. Worst case (no Retry-After header, every
    /// attempt maxing out the backoff) is now ~9 minutes of total waiting
    /// before giving up, versus ~2 minutes before.
    static let maxRateLimitRetries = 9
    static let maxTransientRetries = 1
    /// A dropped connection (Wi-Fi blip, the Mac waking from sleep) usually
    /// recovers within seconds to a couple of minutes; one 2s retry used to turn
    /// that into a dead job. 2+4+8+16+30×4 ≈ 2.5 minutes of waiting before
    /// giving up.
    static let maxNetworkRetries = 8

    /// Surfaced 429s give no visibility into whether the retry loop actually
    /// ran, how long it waited, or what Retry-After said — logged here (via
    /// Console.app, not just Xcode's console, since this app is usually run
    /// standalone) so a failure can be diagnosed after the fact instead of
    /// guessed at.
    private static let logger = Logger(subsystem: "com.bard.Bard", category: "MistralOCR")

    private func post(
        to url: URL, body: [String: Any], attempt: Int,
        startedAt: Date = Date(), sawRetryAfter: Bool = false, networkAttempt: Int = 0
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            if networkAttempt < Self.maxNetworkRetries {
                let sleepSeconds = min(30, pow(2, Double(networkAttempt + 1)))
                Self.logger.warning(
                    "Network error on \(url.lastPathComponent, privacy: .public) (attempt \(networkAttempt + 1, privacy: .public)/\(Self.maxNetworkRetries, privacy: .public)): \(error.localizedDescription, privacy: .public), sleeping \(sleepSeconds, format: .fixed(precision: 0), privacy: .public)s"
                )
                try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                return try await post(
                    to: url, body: body, attempt: attempt,
                    startedAt: startedAt, sawRetryAfter: sawRetryAfter, networkAttempt: networkAttempt + 1
                )
            }
            throw MistralOCRError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MistralOCRError.httpError(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 429, attempt < Self.maxRateLimitRetries {
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let backoff = retryAfter ?? min(90, pow(2, Double(attempt + 1)))
                // Jitter on top of the base backoff: cleanup fires up to
                // maxConcurrentCleanupChunks requests per batch, so when a
                // whole batch gets 429'd together they'd otherwise all sleep
                // for the same duration and retry in lockstep, colliding
                // again on the very next attempt.
                let jitter = Double.random(in: 0...1.5)
                let sleepSeconds = backoff + jitter
                let retryAfterDescription = retryAfter.map { "\($0)" } ?? "none"
                Self.logger.warning(
                    "429 on \(url.lastPathComponent, privacy: .public) (attempt \(attempt + 1, privacy: .public)/\(Self.maxRateLimitRetries, privacy: .public)), retry-after header=\(retryAfterDescription, privacy: .public), sleeping \(sleepSeconds, format: .fixed(precision: 1), privacy: .public)s"
                )
                try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                return try await post(
                    to: url, body: body, attempt: attempt + 1,
                    startedAt: startedAt, sawRetryAfter: sawRetryAfter || retryAfter != nil,
                    networkAttempt: networkAttempt
                )
            }
            if http.statusCode >= 500, attempt < Self.maxTransientRetries {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await post(
                    to: url, body: body, attempt: attempt + 1,
                    startedAt: startedAt, sawRetryAfter: sawRetryAfter, networkAttempt: networkAttempt
                )
            }
            if http.statusCode == 429 {
                let elapsed = Date().timeIntervalSince(startedAt)
                Self.logger.error(
                    "Giving up on \(url.lastPathComponent, privacy: .public) after \(attempt + 1, privacy: .public) attempts, still 429"
                )
                // A real traffic-driven rate limit almost always tells you
                // when to come back; minutes of 429s with no Retry-After
                // ever, across many attempts, is the account being blocked
                // outright rather than merely busy — see persistentRateLimit.
                if !sawRetryAfter, attempt + 1 >= Self.maxRateLimitRetries {
                    throw MistralOCRError.persistentRateLimit(attempts: attempt + 1, elapsed: elapsed)
                }
            }
            throw MistralOCRError.httpError(http.statusCode, bodyText)
        }
        return data
    }
}
