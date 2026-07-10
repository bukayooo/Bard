import Foundation

enum MistralOCRError: Error, LocalizedError {
    case missingAPIKey
    case httpError(Int, String)
    case emptyResponse
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Mistral API key set. Add one in Settings."
        case .httpError(let code, let body): return "Mistral request failed (\(code)): \(body)"
        case .emptyResponse: return "Mistral returned an empty response."
        case .decodeFailed(let msg): return "Could not parse Mistral response: \(msg)"
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
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> BookText {
        let pdfChunks = try PDFSplitter.splitIntoChunks(url: url, maxPages: Self.maxOCRPagesPerChunk)
        let pages = try await runOCR(pdfChunks: pdfChunks, onProgress: onProgress)
        guard !pages.isEmpty else { return BookText(title: "", author: "", content: "") }

        let (title, author, startIndex) = try await detectFrontMatter(pages: pages)

        let contentPages = Array(pages[startIndex...])
        let cleaned = try await cleanUp(pages: contentPages, onProgress: onProgress)

        return BookText(title: title, author: author, content: cleaned.joined(separator: "\n\n"))
    }

    // MARK: - Phase 1: raw OCR

    private func runOCR(
        pdfChunks: [Data],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> [String] {
        let total = pdfChunks.count
        var results = [[String]?](repeating: nil, count: total)
        var completed = 0

        var index = 0
        while index < total {
            let batchEnd = min(index + Self.maxConcurrentOCRChunks, total)
            try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
                for i in index..<batchEnd {
                    let data = pdfChunks[i]
                    group.addTask {
                        let pages = try await ocrChunk(pdfData: data)
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
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> [String] {
        let total = pages.count
        guard total > 0 else { return [] }
        var results = [String?](repeating: nil, count: total)
        var completed = 0

        var index = 0
        while index < total {
            let batchEnd = min(index + Self.maxConcurrentCleanupChunks, total)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in index..<batchEnd {
                    let page = pages[i]
                    group.addTask {
                        let cleaned = try await chat(prompt: Self.cleanupPrompt, userContent: page)
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
    /// ride out a rate-limit window.
    static let maxRateLimitRetries = 6
    static let maxTransientRetries = 1

    private func post(to url: URL, body: [String: Any], attempt: Int) async throws -> Data {
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
        } catch {
            if attempt < Self.maxTransientRetries {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await post(to: url, body: body, attempt: attempt + 1)
            }
            throw MistralOCRError.decodeFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MistralOCRError.httpError(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 429, attempt < Self.maxRateLimitRetries {
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let backoff = retryAfter ?? min(60, pow(2, Double(attempt + 1)))
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                return try await post(to: url, body: body, attempt: attempt + 1)
            }
            if http.statusCode >= 500, attempt < Self.maxTransientRetries {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await post(to: url, body: body, attempt: attempt + 1)
            }
            throw MistralOCRError.httpError(http.statusCode, bodyText)
        }
        return data
    }
}
