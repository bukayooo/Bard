import Foundation

enum TextCleanupError: Error, LocalizedError {
    case missingAPIKey
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Mistral API key set. Add one in Settings."
        case .httpError(let code, let body): return "Mistral request failed (\(code)): \(body)"
        case .emptyResponse: return "Mistral returned an empty response."
        }
    }
}

/// Runs already-extracted book text (epub/txt sources, which — unlike PDFs —
/// never go through an LLM at all during extraction) through the same style of
/// per-chunk cleanup MistralOCRService applies to OCR output: fixes extraction
/// artifacts without changing wording, and translates/modernizes a chunk only
/// if it's entirely non-English or entirely archaic-spelled English, leaving an
/// embedded quote/reference in another language alone. Triggered manually via
/// the Review screen's Cleanup button rather than automatically, since running
/// an LLM pass over every book isn't free and most epub/txt extractions don't
/// need it.
struct TextCleanupService: Sendable {
    static let chatEndpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!
    static let model = "mistral-medium-latest"

    /// Kept small, mirroring MistralOCRService's per-page cleanup chunking, so a
    /// single call only ever has to edit a small, boundable amount of text.
    static let paragraphsPerChunk = 25
    static let maxConcurrentChunks = 3
    static let maxRateLimitRetries = 6
    static let maxTransientRetries = 1

    static let prompt = """
        You are cleaning up plain text extracted from an ebook. It may contain \
        extraction artifacts like broken mid-sentence line breaks, stray markup \
        or HTML-entity leftovers, and irregular spacing. It may also still \
        contain footnote reference markers that survived extraction as plain \
        digits, since the original superscript/bracket formatting is usually \
        lost - e.g. a word immediately followed by a small number with no \
        space ("...as noted31 by the author...") or by a bracketed/parenthesized \
        number ("...as noted[31] by the author..." or "...as noted(31)..."). \
        Your jobs are: (1) fix formatting artifacts - rejoin wrongly-broken \
        lines, remove stray markup/entities, normalize spacing - without \
        changing any wording; (2) remove footnote reference markers like the \
        ones described above, deleting only the marker (and any brackets/parens \
        around it) and leaving the word it's attached to and the surrounding \
        text untouched; (3) if this chunk's body text is written ENTIRELY in a \
        non-English language, or entirely in archaic English spelling/vocabulary \
        that a modern text-to-speech voice would mispronounce (e.g. Middle or \
        Early Modern English like "vnderstand" for "understand", "historie" for \
        "history", "sayth" for "says"), translate/modernize the WHOLE chunk into \
        fluent modern English, keeping the original meaning, sentence order, and \
        paragraph breaks as close as possible. Otherwise - meaning any chunk \
        that is normal modern English, or modern English with only a portion \
        (a quotation, an epigraph, a foreign phrase) in another language or \
        archaic spelling - leave that portion exactly as it appears: the \
        author is likely quoting or referencing something deliberately, and \
        only a chunk that is uniformly foreign or archaic should be translated.

        Critical rules:
        - Outside of fixing formatting artifacts, removing footnote markers, \
        and the whole-chunk translation case above, never invent, complete, \
        paraphrase, summarize, or omit any text. Every word you output must \
        reflect the input.
        - Only remove a number as a footnote marker if it's a small integer \
        directly attached to a word (no space) or alone in brackets/parens \
        right after a word, with no other punctuation suggesting it's part of \
        the sentence itself. If a number could plausibly be real body text \
        (a year, a quantity, a list item, a chapter/section number on its own \
        line, part of a proper noun) rather than a footnote marker, keep it - \
        deleting real content is a worse mistake than leaving in a stray number.
        - Preserve chapter heading lines (starting with "# ") exactly as they \
        appear, character for character - do not translate or reword them, and \
        don't treat a number in one as a footnote marker.
        - This chunk is a fragment of a much longer book, so it will often \
        start or end mid-sentence. Keep the partial sentence exactly as it \
        appears (translated if the whole-chunk case applies), don't drop it \
        and don't try to complete it.
        - If you're unsure whether a chunk qualifies for whole-chunk \
        translation, don't translate it - leave it exactly as-is.

        Reply with only the cleaned (and, if applicable, translated) text and \
        nothing else - no preamble, no explanation, no code fences.
        """

    private let apiKey: String

    init(apiKey: String) throws {
        guard !apiKey.isEmpty else { throw TextCleanupError.missingAPIKey }
        self.apiKey = apiKey
    }

    /// Cleans `text` chunk by chunk, reporting (completed, total) as chunks
    /// finish. The leading "Title: ...\nAuthor: ..." header that epub2tts-edge
    /// and Bard's own PDF pipeline both prefix book text with (see
    /// BookProgressEstimator) is set aside first and reattached untouched,
    /// rather than risking the model rewording or translating it.
    func cleanUp(text: String, onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> String {
        let (header, body) = Self.splitHeader(from: text)
        let chunks = Self.chunk(body: body)
        guard !chunks.isEmpty else { return text }

        var results = [String?](repeating: nil, count: chunks.count)
        var completed = 0

        var index = 0
        while index < chunks.count {
            let batchEnd = min(index + Self.maxConcurrentChunks, chunks.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in index..<batchEnd {
                    let chunk = chunks[i]
                    group.addTask {
                        let cleaned = try await chat(userContent: chunk)
                        return (i, cleaned)
                    }
                }
                for try await (i, cleaned) in group {
                    results[i] = cleaned
                    completed += 1
                    onProgress(completed, chunks.count)
                }
            }
            index = batchEnd
        }

        let cleanedBody = results.compactMap { $0 }.joined(separator: "\n\n")
        return header.isEmpty ? cleanedBody : header + "\n\n" + cleanedBody
    }

    private static func splitHeader(from text: String) -> (header: String, body: String) {
        var lines = text.components(separatedBy: "\n")
        var headerLineCount = 0
        for line in lines.prefix(2) {
            guard line.hasPrefix("Title:") || line.hasPrefix("Author:") else { break }
            headerLineCount += 1
        }
        guard headerLineCount > 0 else { return ("", text) }
        let header = lines.prefix(headerLineCount).joined(separator: "\n")
        lines.removeFirst(headerLineCount)
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (header, body)
    }

    private static func chunk(body: String) -> [String] {
        let paragraphs = body.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !paragraphs.isEmpty else { return [] }
        var chunks: [String] = []
        var start = 0
        while start < paragraphs.count {
            let end = min(start + paragraphsPerChunk, paragraphs.count)
            chunks.append(paragraphs[start..<end].joined(separator: "\n\n"))
            start = end
        }
        return chunks
    }

    // MARK: - Chat + retry (mirrors MistralOCRService's own Mistral chat calls)

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    private func chat(userContent: String, attempt: Int = 0) async throws -> String {
        let body: [String: Any] = [
            "model": Self.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": Self.prompt],
                ["role": "user", "content": userContent],
            ],
        ]
        let data = try await post(body: body, attempt: attempt)
        guard let content = (try? JSONDecoder().decode(ChatResponse.self, from: data))?.choices.first?.message.content
        else {
            throw TextCleanupError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func post(body: [String: Any], attempt: Int) async throws -> Data {
        var request = URLRequest(url: Self.chatEndpoint)
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
                return try await post(body: body, attempt: attempt + 1)
            }
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw TextCleanupError.httpError(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 429, attempt < Self.maxRateLimitRetries {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let backoff = retryAfter ?? min(60, pow(2, Double(attempt + 1)))
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                return try await post(body: body, attempt: attempt + 1)
            }
            if http.statusCode >= 500, attempt < Self.maxTransientRetries {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await post(body: body, attempt: attempt + 1)
            }
            throw TextCleanupError.httpError(http.statusCode, bodyText)
        }
        return data
    }
}
