import Foundation

struct OCRAnnotation: Decodable {
    let title: String
    let author: String
    let content: String
}

private struct OCRResponse: Decodable {
    let documentAnnotation: String?
    enum CodingKeys: String, CodingKey {
        case documentAnnotation = "document_annotation"
    }
}

enum MistralOCRError: Error, LocalizedError {
    case missingAPIKey
    case badSchema
    case httpError(Int, String)
    case emptyAnnotation
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Mistral API key set. Add one in Settings."
        case .badSchema: return "Could not load the bundled OCR response schema."
        case .httpError(let code, let body): return "Mistral OCR request failed (\(code)): \(body)"
        case .emptyAnnotation: return "Mistral OCR returned no structured annotation."
        case .decodeFailed(let msg): return "Could not parse Mistral OCR response: \(msg)"
        }
    }
}

/// Client for Mistral's OCR endpoint using document_annotation_format to pull
/// structured {title, author, content} out of a PDF per the user's schema/prompt.
///
/// IMPORTANT: Mistral caps document_annotation_format at 8 pages per request, so
/// PDFSplitter pre-splits the source PDF into <=8-page chunks and this service
/// annotates each chunk independently, concatenating the results in page order.
struct MistralOCRService: Sendable {
    static let endpoint = URL(string: "https://api.mistral.ai/v1/ocr")!
    static let maxPagesPerChunk = 8
    static let maxConcurrentChunks = 3

    static let annotationPrompt = """
        Always begin the output with exactly 'Title: [exact book title]' on the first line, \
        followed by 'Author: [exact book author]' on the next line. Then extract the main \
        content. Skip all preliminary pages (title, copyright, etc.) until you locate the \
        Table of Contents. Start full extraction from the main content after the TOC. Ignore \
        and discard all footnotes, footnote references (e.g., superscripts like [1]), page \
        headers, footers, images, and any margin line numbers or page numbers. Focus only on \
        the main body text in reading order.
        """

    private let apiKey: String
    private let schemaData: Data

    struct BookText {
        var title: String
        var author: String
        var content: String
    }

    init(apiKey: String) throws {
        guard !apiKey.isEmpty else { throw MistralOCRError.missingAPIKey }
        self.apiKey = apiKey
        guard let url = Bundle.main.url(forResource: "ocrschema", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            throw MistralOCRError.badSchema
        }
        self.schemaData = data
    }

    /// Splits the PDF into <=8-page chunks, annotates each via Mistral's OCR
    /// document_annotation_format, and concatenates the results in order.
    func convertPDF(url: URL, onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> BookText {
        let chunks = try PDFSplitter.splitIntoChunks(url: url, maxPages: Self.maxPagesPerChunk)
        let total = chunks.count
        var results = [OCRAnnotation?](repeating: nil, count: total)
        var completed = 0

        var index = 0
        while index < total {
            let batchEnd = min(index + Self.maxConcurrentChunks, total)
            try await withThrowingTaskGroup(of: (Int, OCRAnnotation).self) { group in
                for i in index..<batchEnd {
                    let data = chunks[i]
                    group.addTask {
                        let annotation = try await annotate(pdfData: data)
                        return (i, annotation)
                    }
                }
                for try await (i, annotation) in group {
                    results[i] = annotation
                    completed += 1
                    onProgress(completed, total)
                }
            }
            index = batchEnd
        }

        var title = ""
        var author = ""
        var contentParts: [String] = []
        for (i, result) in results.enumerated() {
            guard let result else { continue }
            if title.isEmpty, !result.title.trimmingCharacters(in: .whitespaces).isEmpty {
                title = result.title
            }
            if author.isEmpty, !result.author.trimmingCharacters(in: .whitespaces).isEmpty {
                author = result.author
            }
            var chunkContent = result.content
            if i > 0 {
                chunkContent = Self.stripLeadingTitleAuthorLines(chunkContent)
            }
            if !chunkContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentParts.append(chunkContent)
            }
        }
        return BookText(title: title, author: author, content: contentParts.joined(separator: "\n\n"))
    }

    private static func stripLeadingTitleAuthorLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first,
            first.hasPrefix("Title:") || first.hasPrefix("Author:")
                || first.trimmingCharacters(in: .whitespaces).isEmpty
        {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func annotate(pdfData: Data, attempt: Int = 0) async throws -> OCRAnnotation {
        guard let schema = try? JSONSerialization.jsonObject(with: schemaData) else {
            throw MistralOCRError.badSchema
        }
        let base64 = pdfData.base64EncodedString()
        let body: [String: Any] = [
            "model": "mistral-ocr-latest",
            "document": [
                "type": "document_url",
                "document_url": "data:application/pdf;base64,\(base64)",
            ],
            "include_image_base64": false,
            "document_annotation_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "response_schema",
                    "schema": schema,
                    "strict": true,
                ],
            ],
            "document_annotation_prompt": Self.annotationPrompt,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if attempt < 1 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await annotate(pdfData: pdfData, attempt: attempt + 1)
            }
            throw MistralOCRError.decodeFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MistralOCRError.httpError(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if attempt < 1, http.statusCode == 429 || http.statusCode >= 500 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await annotate(pdfData: pdfData, attempt: attempt + 1)
            }
            throw MistralOCRError.httpError(http.statusCode, bodyText)
        }

        let decoded: OCRResponse
        do {
            decoded = try JSONDecoder().decode(OCRResponse.self, from: data)
        } catch {
            throw MistralOCRError.decodeFailed(error.localizedDescription)
        }
        guard let annotationString = decoded.documentAnnotation,
            let annotationData = annotationString.data(using: .utf8)
        else {
            throw MistralOCRError.emptyAnnotation
        }
        do {
            return try JSONDecoder().decode(OCRAnnotation.self, from: annotationData)
        } catch {
            throw MistralOCRError.decodeFailed(error.localizedDescription)
        }
    }
}
