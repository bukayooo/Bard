import AppKit
import Foundation
import PDFKit

enum PDFSplitterError: Error, LocalizedError {
    case cannotLoad
    case emptyDocument
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .cannotLoad: return "Could not load the PDF file."
        case .emptyDocument: return "The PDF file has no pages."
        case .renderFailed: return "Could not render the PDF page to an image."
        }
    }
}

enum PDFSplitter {
    static func pageCount(of url: URL) throws -> Int {
        guard let doc = PDFDocument(url: url) else { throw PDFSplitterError.cannotLoad }
        return doc.pageCount
    }

    /// Splits a PDF into consecutive chunks of at most `maxPages` pages each,
    /// returning the PDF bytes for every chunk in page order. Mistral's
    /// document_annotation_format is capped at 8 pages per request, so chunking
    /// is required for anything longer than that.
    static func splitIntoChunks(url: URL, maxPages: Int = 8) throws -> [Data] {
        guard let doc = PDFDocument(url: url) else { throw PDFSplitterError.cannotLoad }
        let count = doc.pageCount
        guard count > 0 else { throw PDFSplitterError.emptyDocument }

        var chunks: [Data] = []
        var start = 0
        while start < count {
            let end = min(start + maxPages, count)
            let chunkDoc = PDFDocument()
            for pageIndex in start..<end {
                guard let page = doc.page(at: pageIndex) else { continue }
                chunkDoc.insert(page, at: chunkDoc.pageCount)
            }
            guard let data = chunkDoc.dataRepresentation() else {
                throw PDFSplitterError.renderFailed
            }
            chunks.append(data)
            start = end
        }
        return chunks
    }

    /// Renders the first page of the PDF as PNG data, for use as an audiobook cover.
    static func renderFirstPageImage(url: URL, maxDimension: CGFloat = 1200) throws -> Data {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw PDFSplitterError.cannotLoad
        }
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = maxDimension / max(pageBounds.width, pageBounds.height)
        let size = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw PDFSplitterError.renderFailed
        }
        return png
    }
}
